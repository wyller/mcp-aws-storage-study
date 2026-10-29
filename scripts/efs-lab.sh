#!/usr/bin/env bash
# Day 5 helper, run from the repo root. The commands need different identities:
#   scripts/efs-lab.sh status                           default profile: file system, mount targets, APs, policy, clients
#   scripts/efs-lab.sh metrics [minutes]                default profile: CloudWatch I/O bytes and an Elastic cost floor
#   scripts/efs-lab.sh run a|b|both <lab-efs args...>   WRITES (SSM Run Command): run after aws-lab
#   scripts/efs-lab.sh share [tag]                      WRITES: b waits while a writes, then the other way round
#   scripts/efs-lab.sh counter <tag> <n> lock|nolock    WRITES: both clients increment one shared file at once
#   scripts/efs-lab.sh visibility [run]                 WRITES: controlled visibility test, a writes, b reads (~4 min)
# Clients are found by their Name tag, not by the Terraform state, so this also works on leftovers.
# Every command runs the repo's files/lab-efs.sh, shipped inside the SSM command, not the copy
# cloud-init installed: main.tf ignores user_data changes, so editing the helper never stops the EC2.
set -euo pipefail
region=us-east-1
dir="$(cd "$(dirname "$0")/.." && pwd)"
lab_efs="$dir/terraform/efs/files/lab-efs.sh"
visibility_py="$dir/terraform/efs/files/lab-efs-visibility.py"

die() { echo "ERROR: $*" >&2; exit 1; }

instance_of() {
  local id
  id="$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Name,Values=lab-efs-client-$1" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  [[ "$id" == i-* && "$id" != *[[:space:]]* ]] || die "no single running lab-efs-client-$1 (got '$id')"
  echo "$id"
}

file_system_id() {
  local id
  id="$(aws efs describe-file-systems --region "$region" \
    --query 'FileSystems[?Tags[?Key==`Lab`&&Value==`efs`]].FileSystemId' --output text)"
  [[ "$id" == fs-* && "$id" != *[[:space:]]* ]] || die "no single file system tagged Lab=efs (got '$id')"
  echo "$id"
}

status() {
  local fs
  fs="$(file_system_id)"
  echo "== File system $fs"
  aws efs describe-file-systems --region "$region" --file-system-id "$fs" \
    --query 'FileSystems[].{State:LifeCycleState,Throughput:ThroughputMode,Perf:PerformanceMode,Encrypted:Encrypted,Kms:KmsKeyId,AZ:AvailabilityZoneName,Bytes:SizeInBytes.Value,MountTargets:NumberOfMountTargets}' \
    --output table
  echo "== Backup policy (must be DISABLED) and lifecycle (must be empty)"
  aws efs describe-backup-policy --region "$region" --file-system-id "$fs" --query BackupPolicy.Status --output text || true
  aws efs describe-lifecycle-configuration --region "$region" --file-system-id "$fs" --query LifecyclePolicies --output text
  echo "== Mount targets"
  aws efs describe-mount-targets --region "$region" --file-system-id "$fs" \
    --query 'MountTargets[].[MountTargetId,AvailabilityZoneName,IpAddress,LifeCycleState,SubnetId]' --output text
  local mt
  for mt in $(aws efs describe-mount-targets --region "$region" --file-system-id "$fs" --query 'MountTargets[].MountTargetId' --output text); do
    echo "   $mt SGs: $(aws efs describe-mount-target-security-groups --region "$region" --mount-target-id "$mt" --query SecurityGroups --output text)"
  done
  echo "== Access points"
  aws efs describe-access-points --region "$region" --file-system-id "$fs" \
    --query 'AccessPoints[].[AccessPointId,Name,PosixUser.Uid,PosixUser.Gid,RootDirectory.Path,LifeCycleState]' --output text
  echo "== File system policy"
  local policy
  if policy="$(aws efs describe-file-system-policy --region "$region" --file-system-id "$fs" --query Policy --output text 2>&1)"; then
    python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), indent=2))' <<< "$policy"
  else
    echo "(none: any client that reaches a mount target gets full access) $policy"
  fi
  echo "== Clients (tag Lab=efs) and SSM"
  aws ec2 describe-instances --region "$region" --filters Name=tag:Lab,Values=efs \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,Placement.AvailabilityZone,PrivateIpAddress]' --output text
  aws ssm describe-instance-information --region "$region" --filters Key=tag:Lab,Values=efs \
    --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion]' --output text
}

# Byte counts are what moved, not what is billed: Elastic meters each data op at 32 KiB minimum and
# each metadata op at 4 KiB, so 4 KiB I/O bills ~8x its bytes. The cost line is therefore a floor.
metrics() {
  local fs minutes="${1:-180}" start end
  fs="$(file_system_id)"
  end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start="$(date -u -d "-$minutes minutes" +%Y-%m-%dT%H:%M:%SZ)"
  local instances
  instances="$(aws ec2 describe-instances --region "$region" --filters Name=tag:Lab,Values=efs \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  python3 -I - "$fs" "$region" "$start" "$end" $instances <<'EOF'
import json, subprocess, sys
fs, region, start, end = sys.argv[1:5]
instances = sys.argv[5:]
names = ["DataReadIOBytes", "DataWriteIOBytes", "MetadataIOBytes", "TotalIOBytes", "MeteredIOBytes", "ClientConnections"]
queries = [{"Id": n.lower(), "MetricStat": {"Metric": {"Namespace": "AWS/EFS", "MetricName": n,
            "Dimensions": [{"Name": "FileSystemId", "Value": fs}]}, "Period": 60, "Stat": "Sum"}} for n in names]
out = subprocess.run(["aws", "cloudwatch", "get-metric-data", "--region", region, "--start-time", start,
                      "--end-time", end, "--metric-data-queries", json.dumps(queries), "--output", "json"],
                     check=True, capture_output=True, text=True).stdout
res = {r["Id"]: r["Values"] for r in json.loads(out)["MetricDataResults"]}
gib = lambda n: sum(res[n.lower()]) / 2**30
for n in names[:-1]:
    print("%-18s %10.3f GiB" % (n, gib(n)))
conn = res["clientconnections"]
print("%-18s %10.0f max per minute (%d minutes with data)" % ("ClientConnections", max(conn or [0]), len(conn)))
cost = gib("DataReadIOBytes") * 0.03 + (gib("DataWriteIOBytes") + gib("MetadataIOBytes")) * 0.06
print("Elastic cost floor: US$ %.4f (reads 0.03/GB, writes and metadata counted as writes 0.06/GB)" % cost)

# t3 unlimited: 1 surplus credit = 1 vCPU-minute above the baseline, US$ 0.05 per vCPU-hour.
ec2 = [{"Id": "%s_%d" % (m.lower(), i), "MetricStat": {"Metric": {"Namespace": "AWS/EC2", "MetricName": m,
        "Dimensions": [{"Name": "InstanceId", "Value": iid}]}, "Period": 300, "Stat": s}}
       for i, iid in enumerate(instances) for m, s in (("CPUUtilization", "Average"), ("CPUSurplusCreditsCharged", "Sum"))]
if ec2:
    out = subprocess.run(["aws", "cloudwatch", "get-metric-data", "--region", region, "--start-time", start,
                          "--end-time", end, "--metric-data-queries", json.dumps(ec2), "--output", "json"],
                         check=True, capture_output=True, text=True).stdout
    res = {r["Id"]: r["Values"] for r in json.loads(out)["MetricDataResults"]}
    for i, iid in enumerate(instances):
        cpu = res["cpuutilization_%d" % i]
        charged = sum(res["cpusurpluscreditscharged_%d" % i])
        print("%s CPU avg %5.1f%% (baseline 20%%), surplus charged %.1f credits = US$ %.4f" % (
            iid, sum(cpu) / len(cpu) if cpu else 0, charged, charged / 60 * 0.05))
EOF
}

# ssm_send <label> <command> <instance...>: the label is the SSM comment (the command carries base64).
ssm_send() {
  local label="$1" command="$2"; shift 2
  aws ssm send-command --region "$region" --instance-ids "$@" --document-name AWS-RunShellScript \
    --comment "day 5 lab: ${label:0:80}" --timeout-seconds 60 \
    --parameters "$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["600"]}))' "$command")" \
    --query Command.CommandId --output text
}

# Shell command that writes a local file to <dest> on the instance and checks its sha256 there.
ship() {
  local src="$1" dest="$2" sum
  sum="$(sha256sum "$src" | cut -d' ' -f1)"
  printf 'echo %s | base64 -d | gunzip > %s && echo "%s  %s" | sha256sum -c --quiet && chmod 755 %s' \
    "$(gzip -9c "$src" | base64 -w0)" "$dest" "$sum" "$dest" "$dest"
}

# lab-efs <args...> as an SSM command, from the repo copy (sha256 printed for the record).
remote() {
  echo "$(ship "$lab_efs" /tmp/lab-efs-repo) && echo \"lab-efs from the repo, sha256 $(sha256sum "$lab_efs" | cut -c1-12)\" >&2 && /tmp/lab-efs-repo$(printf ' %q' "$@")"
}

# Polls every 2 s for up to 10 min. Prints the final status.
ssm_status() {
  local id="$1" instance="$2" status i
  for i in $(seq 1 300); do
    status="$(aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
      --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Pending|InProgress|Delayed) sleep 2 ;;
      *) break ;;
    esac
  done
  echo "$status"
}

# Prints the output with the client name. Fails unless Success.
ssm_wait() {
  local id="$1" instance="$2" name="$3" status
  status="$(ssm_status "$id" "$instance")"
  aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text | sed "s/^/[$name] /"
  [[ "$status" == Success ]] || { echo "[$name] ended as $status" >&2; return 1; }
}

run() {
  local target="${1:?usage: run a|b|both <lab-efs args...>}" cmd id rc=0 c
  shift
  (($# > 0)) || die "usage: run a|b|both <lab-efs args...>"
  cmd="lab-efs$(printf ' %q' "$@")"
  local -a names
  case "$target" in a|b) names=("$target") ;; both) names=(a b) ;; *) die "target: a, b or both" ;; esac
  local -A ids
  for c in "${names[@]}"; do ids[$c]="$(instance_of "$c")"; done
  id="$(ssm_send "$cmd" "$(remote "$@")" "${ids[@]}")"
  echo "SSM $id: $cmd on ${names[*]}" >&2
  for c in "${names[@]}"; do ssm_wait "$id" "${ids[$c]}" "$c" || rc=1; done
  return $rc
}

# One direction: the reader starts first (it must not find the file yet), then the writer publishes.
# The result is observed_ns (reader clock) - published_ns (writer clock): how long a NEW name takes to
# show up, including the reader's negative lookup cache (up to acdirmax, 60 s). The SSM delivery delay
# happens before either instant, so it is not in it; the clock offset is (chrony, ~ms).
share_one() {
  local tag="$1" wn="$2" wi="$3" rn="$4" ri="$5" r w wout rout pub obs rc=0
  r="$(ssm_send "lab-efs share read $tag 90" "$(remote share read "$tag" 90)" "$ri")"; sleep 3
  w="$(ssm_send "lab-efs share write $tag" "$(remote share write "$tag")" "$wi")"
  wout="$(ssm_wait "$w" "$wi" "$wn")" || rc=1
  rout="$(ssm_wait "$r" "$ri" "$rn")" || rc=1
  printf '%s\n%s\n' "$wout" "$rout"
  pub="$(grep -o 'published_ns=[0-9]*' <<< "$wout" | cut -d= -f2 || true)"
  obs="$(grep -o 'observed_ns=[0-9]*' <<< "$rout" | cut -d= -f2 || true)"
  if [[ -n "$pub" && -n "$obs" ]]; then
    echo "$wn -> $rn: observed - published = $(((obs - pub) / 1000000)) ms (a new name, stat every 200 ms; not the EFS write latency)"
  fi
  return $rc
}

# A new tag per run by default, so a rerun never finds the files of an earlier one.
share() {
  local tag="${1:-s-$(date -u +%m%d-%H%M%S)}" a b rc=0
  [[ "$tag" =~ ^[a-z0-9-]{1,20}$ ]] || die "tag '$tag': lowercase letters, digits and '-', up to 20 characters"
  a="$(instance_of a)"; b="$(instance_of b)"
  echo "share tag $tag" >&2
  share_one "$tag" a "$a" b "$b" || rc=1
  share_one "$tag" b "$b" a "$a" || rc=1
  return $rc
}

# Controlled visibility test (files/lab-efs-visibility.py; README step 4b). Both sides start at the
# same wall-clock instant, 30 s from now, so the SSM delivery falls before the measurement. Raw JSON
# of both clients and the analysis go to notas/dados/efs-dia5/vis-<run>/. Writes ~1 KiB + 9 x 4 KiB
# under /lab/runs/vis-<run> and leaves them there as evidence.
visibility() {
  local run="${1:-v-$(date -u +%m%d-%H%M%S)}" a b start w r dest base rc=0 c
  [[ "$run" =~ ^[a-z0-9-]{1,20}$ ]] || die "run '$run': lowercase letters, digits and '-', up to 20 characters"
  dest="$dir/notas/dados/efs-dia5/vis-$run"
  [[ ! -e "$dest" ]] || die "$dest already exists: use a new run name"
  a="$(instance_of a)"; b="$(instance_of b)"
  start=$(($(date +%s) + 30))
  base="$(ship "$visibility_py" /tmp/lab-efs-visibility.py) && python3 -I /tmp/lab-efs-visibility.py"
  w="$(ssm_send "visibility writer $run" "$base writer $run $start --client a" "$a")"
  r="$(ssm_send "visibility reader $run" "$base reader $run $start --client b" "$b")"
  echo "visibility $run: starts at $(date -u -d "@$start" +%H:%M:%SZ); writer a ($w), reader b ($r); ~4 min" >&2
  mkdir -p "$dest"
  for c in "writer:$w:$a" "reader:$r:$b"; do
    IFS=: read -r name id instance <<< "$c"
    [[ "$(ssm_status "$id" "$instance")" == Success ]] || rc=1
    aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
      --query StandardOutputContent --output text > "$dest/$name.json"
    aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
      --query StandardErrorContent --output text > "$dest/$name.stderr"
  done
  if ((rc != 0)); then
    cat "$dest"/*.stderr >&2
    die "one side failed; raw output kept in $dest"
  fi
  python3 -I "$visibility_py" analyze "$dest/writer.json" "$dest/reader.json" | tee "$dest/analysis.json"
}

counter() {
  local tag="${1:?usage: counter <tag> <n> lock|nolock}" n="${2:?usage: counter <tag> <n> lock|nolock}"
  local mode="${3:?usage: counter <tag> <n> lock|nolock}" a b id rc=0
  a="$(instance_of a)"; b="$(instance_of b)"
  id="$(ssm_send "lab-efs counter init $tag" "$(remote counter init "$tag")" "$a")"; ssm_wait "$id" "$a" a
  # One send-command to both instances: they start within the same second or so.
  id="$(ssm_send "lab-efs counter run $tag $n $mode" "$(remote counter run "$tag" "$n" "$mode")" "$a" "$b")"
  ssm_wait "$id" "$a" a || rc=1; ssm_wait "$id" "$b" b || rc=1
  id="$(ssm_send "lab-efs counter check $tag $((2 * n))" "$(remote counter check "$tag" $((2 * n)))" "$a")"; ssm_wait "$id" "$a" a
  return $rc
}

case "${1:-}" in
  status) status ;;
  metrics) shift; metrics "$@" ;;
  run) shift; run "$@" ;;
  share) shift; share "$@" ;;
  counter) shift; counter "$@" ;;
  visibility) shift; visibility "$@" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
