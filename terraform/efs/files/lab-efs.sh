#!/usr/bin/env bash
# lab-efs: on-instance helper for the Day 5 EFS lab, installed by cloud-init on both clients.
# Run it as root: sudo lab-efs <command> in a Session Manager shell, or through scripts/efs-lab.sh
# (SSM Run Command, already root). Without arguments it prints the usage.
# The IDs come from /etc/lab-efs.env, written by cloud-init from the Terraform state.
# Everything the tests write goes under runs/ in the app access point (/lab on the file system),
# and "clean" removes it. fio results go to /tmp/lab-fio-efs-*.json, where scripts/collect-fio.sh picks them up.
set -euo pipefail

ENV_FILE=/etc/lab-efs.env
MNT_APP=/mnt/efs-app
MNT_OTHER=/mnt/efs-other
MNT_ROOT=/mnt/efs-root
MNT_TRY=/mnt/efs-try
PERF_COUNT=/var/lib/lab-efs/perf-runs

usage() {
  cat <<'EOF'
sudo lab-efs <command>
  status                         env, EFS mounts, TLS tunnel processes, package versions
  net [ip]                       DNS of the file system (own-AZ mount target) and TCP 2049, 3 s timeout
  mount app|other|root           TLS + IAM mount; app/other through their access point, root without one
                                 (MT_IP=<ip> lab-efs mount ... forces a mount target: cross-AZ test)
  umount app|other|root|try|all  unmount; lists who holds it if busy
  try notls|noiam|blocked        a new mount expected to fail, classified NETWORK/POLICY/CLIENT;
                                 if it mounts, it is unmounted at once
  verify app|other|root          TLS tunnel, NFS 4.1 options and (app) the identity written on the server
  probe                          a write + read on the app mount that must finish within 10 s
  share write|read <tag> [s]     one client writes runs/share-<tag>/from-<client>.txt, the other waits for it
  counter init|run|check <tag>   shared counter: run <tag> <n> lock|nolock; check <tag> <expected>
  perms                          POSIX checks across the app, other and root mounts (all three mounted)
  perf <name> [local]            capped fio + small files on the app mount (1 run per client),
                                 or on the root EBS volume (local) as the control
  clean [tag]                    delete runs/ (or the runs of one tag) on the app mount
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

load_env() {
  [[ -r "$ENV_FILE" ]] || die "$ENV_FILE missing: cloud-init not finished? (cloud-init status --long)"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  [[ "${FS_ID:-}" == fs-* && "${AP_APP:-}" == fsap-* && "${AP_OTHER:-}" == fsap-* && -n "${CLIENT:-}" ]] ||
    die "$ENV_FILE is incomplete"
}

mnt_of() {
  case "$1" in
    app) echo "$MNT_APP" ;;
    other) echo "$MNT_OTHER" ;;
    root) echo "$MNT_ROOT" ;;
    try) echo "$MNT_TRY" ;;
    *) die "unknown mount '$1' (app, other, root, try)" ;;
  esac
}

valid_tag() {
  [[ "$1" =~ ^[a-z0-9-]{1,20}$ ]] || die "tag '$1': lowercase letters, digits and '-', up to 20 characters"
}

# Day 1 lesson: a directory that is not a mount point silently writes to the root volume.
# Here it must also be EFS through the TLS tunnel: NFS 4.x whose server is 127.0.0.1.
require_efs() {
  local m="$1" fstype src
  mountpoint -q "$m" || die "$m is not a mount point; run: lab-efs mount <app|other|root>"
  fstype="$(findmnt -n -o FSTYPE "$m")"
  src="$(findmnt -n -o SOURCE "$m")"
  [[ "$fstype" == nfs4 ]] || die "$m is $fstype, not nfs4"
  [[ "$src" == 127.0.0.1:* ]] || die "$m comes from $src, not from the local TLS tunnel (127.0.0.1)"
}

# expect ok|fail <description> <command...>: runs the command and compares its outcome. Never exits.
FAILS=0
expect() {
  local want="$1" what="$2" out rc got=ok
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || got=fail
  if [[ "$got" == "$want" ]]; then
    echo "PASS  $what"
  else
    echo "FAIL  $what (expected $want, got $got)"
    FAILS=$((FAILS + 1))
  fi
  if [[ -n "$out" ]]; then sed 's/^/        /' <<< "$out"; fi
  return 0
}

# A POSIX denial: the command fails WITH EACCES or EPERM. Any other failure (EIO, a timeout, a stale
# handle) would be another layer, so it counts as a FAIL even though the command failed.
denied() {
  local what="$1" out rc
  shift
  set +e
  out="$(timeout -k 2 15 "$@" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]] && grep -qE 'Permission denied|Operation not permitted' <<< "$out"; then
    echo "PASS  $what"
  else
    echo "FAIL  $what (expected EACCES/EPERM, got exit $rc)"
    FAILS=$((FAILS + 1))
  fi
  if [[ -n "$out" ]]; then sed 's/^/        /' <<< "$out"; fi
  return 0
}

cmd_status() {
  load_env
  echo "== $ENV_FILE"; cat "$ENV_FILE"
  echo "== cloud-init: $(cloud-init status 2>/dev/null || echo unknown)"
  echo "== packages"; rpm -q amazon-efs-utils fio nfs-utils || true
  echo "== NFS mounts"; findmnt -t nfs4 -o TARGET,SOURCE,OPTIONS || echo "(none)"
  echo "== TLS tunnels"; pgrep -a -f 'efs-proxy|stunnel' || echo "(none)"
}

# The file system DNS name resolves, inside the VPC, to the mount target of the client's own AZ.
# A security group that drops 2049 shows up as no answer (timeout), not as a refusal.
cmd_net() {
  load_env
  local dns="$FS_ID.efs.$REGION.amazonaws.com" token az ip
  token="$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  az="$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone)"
  echo "client $CLIENT in $az"
  ip="${1:-$(getent hosts "$dns" | awk '{print $1; exit}')}"
  [[ -n "$ip" ]] || die "$dns does not resolve (mount target not available yet, or VPC DNS off)"
  echo "$dns -> $ip"
  if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/2049" 2>/dev/null; then
    echo "TCP $ip:2049 open"
  else
    echo "TCP $ip:2049 no answer in 3 s (SG, NACL or route)"
  fi
}

mount_opts() {
  case "$1" in
    app) echo "tls,iam,accesspoint=$AP_APP" ;;
    other) echo "tls,iam,accesspoint=$AP_OTHER" ;;
    root) echo "tls,iam" ;;
  esac
}

cmd_mount() {
  local name="${1:?usage: mount app|other|root}" m opts
  load_env
  [[ "$name" != try ]] || die "use lab-efs try <case>"
  m="$(mnt_of "$name")"
  mountpoint -q "$m" && die "$m is already mounted (lab-efs umount $name)"
  opts="$(mount_opts "$name")${MT_IP:+,mounttargetip=$MT_IP}"
  mkdir -p "$m"
  echo "mount -t efs -o $opts $FS_ID:/ $m"
  timeout -k 5 "${MOUNT_TIMEOUT:-90}" mount -t efs -o "$opts" "$FS_ID:/" "$m" ||
    die "mount failed or timed out after ${MOUNT_TIMEOUT:-90} s (README: Tests and troubleshooting)"
  findmnt -n -o TARGET,SOURCE,FSTYPE "$m"
}

cmd_umount() {
  local name="${1:?usage: umount app|other|root|try|all}" m n
  if [[ "$name" == all ]]; then
    for n in app other root try; do cmd_umount "$n" || true; done
    return 0
  fi
  m="$(mnt_of "$name")"
  if ! mountpoint -q "$m"; then
    echo "$m: not mounted"
    return 0
  fi
  if ! umount "$m"; then
    command -v fuser >/dev/null && fuser -vm "$m" || true
    die "$m is busy: leave the directory or stop whoever holds it (listed above), then retry"
  fi
  echo "$m: unmounted"
}

# Mounts expected to FAIL, each on a NEW connection (its own mount point and TLS tunnel), so a
# stateful SG never lets it through on an already-tracked flow. Nothing stays mounted afterwards.
#   notls    plain NFS through the helper: no TLS and no IAM (anonymous)
#   noiam    TLS but anonymous: the policy only allows the lab role (with allow_anonymous = true, it mounts)
#   blocked  the right options; run it with nfs_ingress_enabled = false (times out)
# The RESULT line names the layer from the evidence: timeout = NETWORK, "access denied" = POLICY.
# POSIX denials never show up here: they need a successful mount (see perms).
cmd_try() {
  local case_="${1:?usage: try notls|noiam|blocked}" opts t0 rc out
  load_env
  mountpoint -q "$MNT_TRY" && die "$MNT_TRY is still mounted; lab-efs umount try"
  case "$case_" in
    notls) opts="" ;;
    noiam) opts="tls" ;;
    blocked) opts="tls,iam,accesspoint=$AP_APP" ;;
    *) die "unknown case '$case_' (notls, noiam, blocked)" ;;
  esac
  mkdir -p "$MNT_TRY"
  echo "mount -t efs ${opts:+-o $opts} $FS_ID:/ $MNT_TRY (timeout ${TRY_TIMEOUT:-45} s)"
  t0=$(date +%s)
  set +e
  out="$(timeout -k 5 "${TRY_TIMEOUT:-45}" mount -t efs ${opts:+-o "$opts"} "$FS_ID:/" "$MNT_TRY" 2>&1)"
  rc=$?
  set -e
  [[ -z "$out" ]] || sed 's/^/  | /' <<< "$out"
  echo "exit $rc after $(($(date +%s) - t0)) s"
  if mountpoint -q "$MNT_TRY"; then
    echo "RESULT: MOUNTED. Root of the file system as seen here: $(stat -c '%u:%g %A' "$MNT_TRY")"
    umount "$MNT_TRY"
    echo "rolled back: $MNT_TRY unmounted"
  else
    # A killed mount can leave its TLS tunnel behind; the efs-utils watchdog would reap it later.
    pkill -f "mnt\.efs-try" 2>/dev/null || true
    if [[ $rc -eq 124 || $rc -eq 137 ]] || grep -qiE 'timed out|no route|connection refused' <<< "$out"; then
      echo "RESULT: NETWORK (no answer from the mount target: SG, NACL, route or DNS)"
    elif grep -qi 'access denied' <<< "$out"; then
      echo "RESULT: POLICY (the server answered and refused: file system policy, TLS or IAM identity)"
    else
      echo "RESULT: CLIENT (failed before asking the server: options, credentials, efs-utils; see /var/log/amazon/efs/mount.log)"
    fi
  fi
}

cmd_verify() {
  local name="${1:?usage: verify app|other|root}" m opts f
  load_env
  m="$(mnt_of "$name")"
  require_efs "$m"
  opts="$(findmnt -n -o OPTIONS "$m")"
  echo "$(findmnt -n -o TARGET,SOURCE,FSTYPE "$m")"
  echo "options: $opts"
  echo "mount.efs: $(mount.efs --version 2>&1 | head -n 1)"
  FAILS=0
  expect ok "TLS: served by the local tunnel (127.0.0.1)" bash -c "findmnt -n -o SOURCE '$m' | grep -q '^127.0.0.1:'"
  expect ok "TLS: a tunnel process is running" pgrep -a -f 'efs-proxy|stunnel'
  expect ok "NFS 4.1" grep -q 'vers=4.1' <<< "$opts"
  expect ok "rsize and wsize 1 MiB" bash -c "grep -q 'rsize=1048576' <<< '$opts' && grep -q 'wsize=1048576' <<< '$opts'"
  expect ok "hard mount (retries forever instead of returning EIO)" grep -qw hard <<< "$opts"
  expect ok "noresvport (a new source port on reconnect)" grep -qw noresvport <<< "$opts"
  expect ok "df shows the 8 EiB virtual size" df -h "$m"
  if [[ "$name" == app ]]; then
    mkdir -p "$m/runs"
    f="$m/runs/.verify-$CLIENT"
    expect ok "a file created by root is owned by 1001:1001 on the server" \
      bash -c "touch '$f' && stat -c '%u:%g %n' '$f' && [[ \$(stat -c %u:%g '$f') == 1001:1001 ]]"
    rm -f "$f"
  fi
  echo "$FAILS check(s) differ from the expected"
}

cmd_probe() {
  local f t0
  load_env
  require_efs "$MNT_APP"
  f="$MNT_APP/runs/probe-$CLIENT"
  t0=$(date +%s%N)
  if timeout -k 2 10 bash -c 'mkdir -p "${1%/*}" && date +%s%N > "$1" && sync "$1" && cat "$1" >/dev/null && rm -f "$1"' _ "$f"; then
    echo "probe OK in $((($(date +%s%N) - t0) / 1000000)) ms"
  else
    die "probe did not finish in 10 s (hard mount waiting on the server: SG, network or mount target)"
  fi
}

# Write and read run on different clients. The file appears under its final name only after it is
# complete (rename), and its sha256 is written before it, so the reader never checks a half file.
# Two instants, from two clocks (chrony): published_ns on the writer, right after the rename
# returns; observed_ns on the reader, when stat first sees the name. Their difference is the time
# a NEW name takes to show up on the other client, which includes the reader's NFS caches: a
# negative lookup ("no such file") is kept until the parent directory's cached attributes expire
# (acdirmin 30 s, growing to acdirmax 60 s by default). It is not the EFS write latency.
cmd_share() {
  local sub="${1:?usage: share write|read <tag> [seconds]}" tag="${2:?usage: share write|read <tag> [seconds]}"
  local d f other secs t0 deadline observed published
  load_env
  require_efs "$MNT_APP"
  valid_tag "$tag"
  d="$MNT_APP/runs/share-$tag"
  case "$sub" in
    write)
      mkdir -p "$d"
      f="$d/from-$CLIENT.txt"
      [[ ! -e "$f" ]] || die "$f already exists: use a new tag (evidence of earlier runs is kept)"
      {
        echo "tag=$tag client=$CLIENT host=$(hostname)"
        head -c 65536 /dev/urandom | base64 -w0
        echo
      } > "$d/.tmp-$CLIENT"
      sha256sum "$d/.tmp-$CLIENT" | awk '{print $1}' > "$f.sha256"
      mv "$d/.tmp-$CLIENT" "$f"
      published=$(date +%s%N)
      echo "client $CLIENT published $f ($(stat -c %s "$f") bytes) published_ns=$published"
      ;;
    read)
      secs="${3:-60}"
      [[ "$CLIENT" == a ]] && other=b || other=a
      f="$d/from-$other.txt"
      t0=$(date +%s%N)
      # Already there = left by an earlier run: "seeing" it would pass without testing anything.
      [[ ! -e "$f" ]] || die "$f exists before this read started: stale, use a new tag"
      deadline=$(($(date +%s) + secs))
      until [[ -f "$f" ]]; do
        (($(date +%s) < deadline)) || die "no $f after $secs s"
        sleep 0.2
      done
      observed=$(date +%s%N)
      [[ "$(head -n 1 "$f")" == "tag=$tag client=$other "* ]] || die "$f is not from tag $tag, client $other"
      echo "client $CLIENT observed $f observed_ns=$observed after $(((observed - t0) / 1000000)) ms of polling (stat every 200 ms)"
      [[ "$(sha256sum "$f" | awk '{print $1}')" == "$(< "$f.sha256")" ]] || die "sha256 differs"
      echo "OK: sha256 matches"
      ;;
    *) die "usage: share write|read <tag> [seconds]" ;;
  esac
}

# Read-increment-write on one file from both clients at once. Without a lock, updates get lost.
# With one, the NFS lock (flock is a whole-file POSIX lock on NFS, so the fd must be open for write)
# serializes them, and taking it makes the client revalidate its cache.
cmd_counter() {
  local sub="${1:?usage: counter init|run|check <tag> ...}" tag="${2:?usage: counter init|run|check <tag> ...}"
  local d f n mode i v t0
  load_env
  require_efs "$MNT_APP"
  valid_tag "$tag"
  d="$MNT_APP/runs/counter-$tag"
  f="$d/value"
  case "$sub" in
    init)
      rm -rf "$d"
      mkdir -p "$d"
      echo 0 > "$f"
      : > "$d/lock"
      echo "counter $tag = 0"
      ;;
    run)
      n="${3:?usage: counter run <tag> <n> lock|nolock}"
      mode="${4:?usage: counter run <tag> <n> lock|nolock}"
      [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= 2000)) || die "n must be 1..2000"
      [[ "$mode" == lock || "$mode" == nolock ]] || die "mode: lock or nolock"
      [[ -f "$f" ]] || die "run 'counter init $tag' first, on one client"
      t0=$(date +%s%N)
      for ((i = 0; i < n; i++)); do
        if [[ "$mode" == lock ]]; then
          (
            flock 9
            v="$(< "$f")"
            echo $((v + 1)) > "$f"
          ) 9>> "$d/lock"
        else
          v="$(< "$f")"
          echo $((v + 1)) > "$f"
        fi
      done
      echo "client $CLIENT: $n increments ($mode) in $((($(date +%s%N) - t0) / 1000000)) ms"
      ;;
    check)
      n="${3:?usage: counter check <tag> <expected>}"
      v="$(< "$f")"
      if [[ "$v" == "$n" ]]; then
        echo "counter $tag = $v: MATCH"
      else
        echo "counter $tag = '$v', expected $n: LOST $((n - ${v:-0})) update(s)"
      fi
      ;;
    *) die "usage: counter init|run|check <tag> ..." ;;
  esac
}

# Expected results with the stack as written (ClientRootAccess not granted, /lab 1001:1001 0750).
cmd_perms() {
  local d f
  load_env
  require_efs "$MNT_APP"
  require_efs "$MNT_OTHER"
  require_efs "$MNT_ROOT"
  d="$MNT_APP/runs/perms-$CLIENT"
  f="$d/by-root"
  FAILS=0
  rm -rf "$d"
  mkdir -p "$d"
  expect ok "app AP: root creates a file" touch "$f"
  expect ok "app AP: its owner is the AP identity 1001:1001, not 0:0" \
    bash -c "stat -c '%u:%g %A %n' '$f' && [[ \$(stat -c %u:%g '$f') == 1001:1001 ]]"
  expect ok "app AP: user nobody (65534) also writes, as 1001:1001" \
    bash -c "runuser -u nobody -- touch '$d/by-nobody' && [[ \$(stat -c %u:%g '$d/by-nobody') == 1001:1001 ]]"
  denied "app AP: chown to 0:0 is refused (every call runs as 1001)" chown 0:0 "$f"
  expect ok "app AP: chmod works (1001 owns the file)" chmod 0600 "$f"
  expect ok "root mount: /lab is 1001:1001 drwxr-x---" \
    bash -c "stat -c '%u:%g %A %n' '$MNT_ROOT/lab' && [[ \$(stat -c '%u:%g %A' '$MNT_ROOT/lab') == '1001:1001 drwxr-x---' ]]"
  denied "root mount: root is squashed to 65534 and cannot write to /" touch "$MNT_ROOT/squash-$CLIENT"
  denied "root mount: squashed root cannot list /lab (0750)" ls "$MNT_ROOT/lab"
  expect ok "other AP: 1002 lists / (0755)" ls "$MNT_OTHER"
  denied "other AP: 1002 cannot enter /lab (not owner, not group)" ls "$MNT_OTHER/lab"
  denied "other AP: 1002 cannot write to /" touch "$MNT_OTHER/other-$CLIENT"
  # Rollback: whatever a check that should have failed managed to create.
  rm -f "$MNT_ROOT/squash-$CLIENT" "$MNT_OTHER/other-$CLIENT" 2>/dev/null || true
  rm -rf "$d"
  echo "$FAILS check(s) differ from the expected"
}

fio_summary() {
  python3 -I -c '
import json, sys
j = json.load(open(sys.argv[1]))["jobs"][0]
for k in ("read", "write"):
    s = j[k]
    if s["io_bytes"] == 0:
        continue
    p = s["clat_ns"].get("percentile", {})
    print("%-18s %-5s %8.1f MiB/s %8.0f IOPS  p50 %6.2f ms  p99 %6.2f ms" % (
        sys.argv[2], k, s["bw_bytes"] / 1048576, s["iops"],
        p.get("50.000000", 0) / 1e6, p.get("99.000000", 0) / 1e6))
' "$1" "$2"
}

# Every job is capped by size or by op count, never only by time, so a faster or slower EFS cannot
# change the bill. Upper bound of the metered I/O per run on EFS (32 KiB minimum per data op):
#   writes: seqwrite 128 MiB + seqwrite-p4 4 x 32 MiB + randwrite 4000 x 32 KiB (125 MiB) + 300 small files ~= 0.4 GiB
#   reads:  seqread 128 MiB + randread 4000 x 32 KiB (125 MiB)                                            ~= 0.25 GiB
#   => <= US$ 0.03 (0.4 x 0.06 + 0.25 x 0.03), plus metadata, a few MiB. Each job also stops at 30 s.
# QD1 psync on purpose: one NFS round trip per call shows the latency; the 4-job run (4 ops in flight)
# shows that EFS throughput comes from parallelism. direct=1 skips the client page cache; nothing
# skips the EFS server side, so seqread right after seqwrite may be served warm.
PERF_MAX_RUNS=1
cmd_perf() {
  local name="${1:?usage: perf <name> [local]}" where="${2:-efs}" dir job t0 t1 t2 t3 i runs=0
  valid_tag "$name"
  if [[ "$where" == local ]]; then
    dir=/var/tmp/lab-efs-perf
  else
    load_env
    require_efs "$MNT_APP"
    dir="$MNT_APP/runs/perf-$CLIENT"
    # Budget guard: at most PERF_MAX_RUNS runs on EFS per client (PERF_FORCE=1 overrides).
    mkdir -p "${PERF_COUNT%/*}"
    [[ -f "$PERF_COUNT" ]] && runs="$(< "$PERF_COUNT")"
    ((runs < PERF_MAX_RUNS)) || [[ "${PERF_FORCE:-}" == 1 ]] ||
      die "already $runs perf run(s) on EFS from this client (limit $PERF_MAX_RUNS, each <= US\$ 0.03); PERF_FORCE=1 to go on"
    echo $((runs + 1)) > "$PERF_COUNT"
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "fio in $dir ($where); every job capped by size or op count and by 30 s"
  local -a common=(--directory="$dir" --ioengine=psync --direct=1 --group_reporting --output-format=json --runtime=30)
  run_fio() {
    job="$1"
    shift
    fio --name="$job" "${common[@]}" --output="/tmp/lab-fio-efs-$name-$job.json" "$@" >/dev/null
    fio_summary "/tmp/lab-fio-efs-$name-$job.json" "$job"
  }
  run_fio seqwrite --rw=write --bs=1M --size=128M --filename=seq.bin
  run_fio seqread --rw=read --bs=1M --size=128M --filename=seq.bin
  run_fio seqwrite-p4 --rw=write --bs=1M --size=32M --numjobs=4
  run_fio randread-4k --rw=randread --bs=4k --size=128M --filename=seq.bin --number_ios=4000
  run_fio randwrite-4k --rw=randwrite --bs=4k --size=128M --filename=seq.bin --number_ios=4000

  # fsync per file on both sides: NFS flushes on close anyway, a local disk would only fill the page
  # cache, and the comparison would be between a network round trip and memory.
  mkdir -p "$dir/small"
  t0=$(date +%s%N)
  for ((i = 0; i < 300; i++)); do
    head -c 4096 /dev/urandom | dd of="$dir/small/f$i" bs=4096 conv=fsync status=none
  done
  t1=$(date +%s%N)
  ls -l "$dir/small" >/dev/null
  t2=$(date +%s%N)
  rm -rf "$dir/small"
  t3=$(date +%s%N)
  printf '{"where": "%s", "create_300x4k_fsync_ms": %d, "ls_l_ms": %d, "rm_ms": %d}\n' "$where" \
    $(((t1 - t0) / 1000000)) $(((t2 - t1) / 1000000)) $(((t3 - t2) / 1000000)) > "/tmp/lab-fio-efs-$name-smallfiles.json"
  echo "smallfiles: create 300 x 4 KiB + fsync $(((t1 - t0) / 1000000)) ms ($((300000000000 / (t1 - t0 + 1))) files/s);" \
    "ls -l $(((t2 - t1) / 1000000)) ms; rm $(((t3 - t2) / 1000000)) ms"
  rm -rf "$dir"
  echo "results: /tmp/lab-fio-efs-$name-*.json (scripts/collect-fio.sh)"
}

cmd_clean() {
  local tag="${1:-}"
  load_env
  require_efs "$MNT_APP"
  if [[ -n "$tag" ]]; then
    valid_tag "$tag"
    rm -rf "$MNT_APP/runs/"*"-$tag"
  else
    rm -rf "$MNT_APP/runs"
  fi
  rm -rf /var/tmp/lab-efs-perf
  echo "clean: $(find "$MNT_APP" -mindepth 1 | wc -l) entries left in $MNT_APP"
}

main() {
  local cmd="${1:-}"
  shift || true
  [[ -z "$cmd" ]] && { usage; return 0; }
  [[ $EUID -eq 0 ]] || die "run as root: sudo lab-efs $cmd"
  case "$cmd" in
    status) cmd_status ;;
    net) cmd_net "$@" ;;
    mount) cmd_mount "$@" ;;
    umount) cmd_umount "$@" ;;
    try) cmd_try "$@" ;;
    verify) cmd_verify "$@" ;;
    probe) cmd_probe ;;
    share) cmd_share "$@" ;;
    counter) cmd_counter "$@" ;;
    perms) cmd_perms ;;
    perf) cmd_perf "$@" ;;
    clean) cmd_clean "$@" ;;
    *) usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
