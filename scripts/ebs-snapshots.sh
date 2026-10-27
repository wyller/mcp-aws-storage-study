#!/usr/bin/env bash
# Day 4 helper, run from the repo root. The commands need different identities:
#   scripts/ebs-snapshots.sh status                default profile (readonly-user): lab snapshots and volumes
#   scripts/ebs-snapshots.sh blocks <snap> [snap]  EBS direct APIs, denied to readonly-user: run after aws-lab
#   scripts/ebs-snapshots.sh take <label> [--no-freeze]
#                                                  WRITES (SSM + CreateSnapshot): run after aws-lab
# blocks with one snapshot counts the blocks it references (ListSnapshotBlocks); with two, the blocks
# that differ between them (ListChangedBlocks). Each request costs US$ 0.0006 per 1000.
set -euo pipefail
region=us-east-1
dir="$(cd "$(dirname "$0")/.." && pwd)"
stack="$dir/terraform/ebs-snapshots"

die() { echo "ERROR: $*" >&2; exit 1; }

status() {
  echo "== Lab snapshots (tag Lab=ebs-snapshots)"
  aws ec2 describe-snapshots --region "$region" --owner-ids self --filters Name=tag:Lab,Values=ebs-snapshots \
    --query 'sort_by(Snapshots,&StartTime)[].{Label:Tags[?Key==`SnapshotLabel`]|[0].Value,Id:SnapshotId,State:State,Progress:Progress,Start:StartTime,VolGiB:VolumeSize,FullBytes:FullSnapshotSizeInBytes,Tier:StorageTier}' \
    --output table
  echo "== Every snapshot of this account (anything here without the tag is outside the state)"
  aws ec2 describe-snapshots --region "$region" --owner-ids self \
    --query 'Snapshots[].[SnapshotId,State,VolumeId,StartTime,Tags[?Key==`Lab`]|[0].Value]' --output text
  echo "== Volumes"
  aws ec2 describe-volumes --region "$region" \
    --query 'Volumes[].[VolumeId,State,Size,SnapshotId,AvailabilityZone,Attachments[0].Device,Attachments[0].State,Tags[?Key==`Name`]|[0].Value]' \
    --output text
}

# The CLI has no paginator for the EBS direct APIs (botocore ebs paginators-1.json is empty), so a
# single call stops at MaxResults (100 to 10000). This loop follows NextToken until it is absent.
# ListChangedBlocks: a block with no FirstBlockToken is new in the second snapshot; with both
# tokens, it was rewritten. Neither count is the bill: see "Changed blocks are not the bill" in the README.
count_blocks() {
  local op="$1"; shift
  local token="" out
  local -a page
  local pages=0 blocks=0 new=0 size=0
  while :; do
    out="$(aws ebs "$op" --region "$region" --max-results 10000 "$@" ${token:+--next-token "$token"} --output json)"
    mapfile -t page < <(python3 -I -c '
import json, sys
d = json.load(sys.stdin)
b = d.get("ChangedBlocks", d.get("Blocks", []))
print(len(b)); print(sum(1 for x in b if "FirstBlockToken" not in x and "BlockToken" not in x))
print(d.get("BlockSize", 0)); print(d.get("NextToken", ""))' <<< "$out")
    pages=$((pages + 1)); blocks=$((blocks + page[0])); new=$((new + page[1]))
    [[ "${page[2]}" != 0 ]] && size="${page[2]}"
    token="${page[3]}"
    [[ -n "$token" ]] || break
  done
  echo "$op: $blocks blocks of $size bytes = $(( blocks * size / 1048576 )) MiB, in $pages page(s)"
  [[ "$op" == list-changed-blocks ]] && echo "  new in the second: $new; rewritten: $((blocks - new))"
  return 0
}

# Sends one shell command to the instance and polls every 0.5 s (aws ssm wait polls every 5 s,
# which would stretch the freeze). Prints the command's stdout; fails unless it ends in Success.
ssm_run() {
  local instance="$1" command="$2" id status i
  id="$(aws ssm send-command --region "$region" --instance-ids "$instance" --document-name AWS-RunShellScript \
    --comment "day 4 lab: $command" --timeout-seconds 30 \
    --parameters "$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$command")" \
    --query Command.CommandId --output text)"
  for i in $(seq 1 120); do
    status="$(aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
      --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) break ;;
      Pending|InProgress|Delayed) sleep 0.5 ;;
      *) aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
           --query StandardErrorContent --output text >&2 || true
         die "'$command' ended as $status" ;;
    esac
  done
  [[ "$status" == Success ]] || die "'$command' still $status after 60 s"
  aws ssm get-command-invocation --region "$region" --command-id "$id" --instance-id "$instance" \
    --query StandardOutputContent --output text
}

# Thaws and then proves it with a write probe; "thawed" from fsfreeze alone is not trusted.
# 1. Up to 3 tries over SSM (lab-ebs thaw && lab-ebs probe).
# 2. If SSM is the problem, wait for the instance's own auto-thaw (armed by the freeze) and probe again.
# 3. Still not confirmed: stop with the manual steps. A reboot also clears a freeze.
# Sets frozen=no first, so the EXIT trap never runs it twice.
unfreeze() {
  local out i wait_s
  frozen=no
  for i in 1 2 3; do
    if out="$(ssm_run "$instance" "lab-ebs thaw && lab-ebs probe")"; then
      echo "$out"
      [[ "$out" == *"was not frozen"* ]] && echo "WARNING: the auto-thaw ran first; $snap_id may not be filesystem-consistent" >&2
      return 0
    fi
    echo "WARNING: thaw attempt $i of 3 failed" >&2
    sleep $((2 * i))
  done
  wait_s=$(( auto_thaw_at - $(date +%s) ))
  if (( wait_s > 0 )); then
    echo "Waiting ${wait_s}s for the auto-thaw on the instance..." >&2
    sleep "$wait_s"
  fi
  if out="$(ssm_run "$instance" "lab-ebs probe")"; then
    echo "$out (thawed by the auto-thaw; $snap_id may not be filesystem-consistent)"
    return 0
  fi
  cat >&2 <<EOF2
ERROR: could not confirm that /mnt/lab-data is thawed on $instance.
  1. Open a session (console: EC2 > instance > Connect > Session Manager) and run:
       sudo lab-ebs thaw; sudo lab-ebs probe
  2. If no session opens either: aws ec2 reboot-instances --instance-ids $instance
     (a freeze does not survive a reboot; remount with lab-ebs mount afterwards)
EOF2
  return 1
}

on_exit() {
  local rc=$?
  [[ "$frozen" == yes ]] && { unfreeze || rc=1; }
  if [[ -n "$snap_id" && "$done_ok" != yes ]]; then
    echo "NOTE: $snap_id was created and is outside the state: import it (snapshot_ids) or delete it." >&2
  elif [[ "$create_tried" == yes && -z "$snap_id" ]]; then
    echo "NOTE: create-snapshot failed on the client side; it may still exist. Check: $0 status" >&2
  fi
  exit "$rc"
}

# freeze -> CreateSnapshot -> thaw from one place, so the freeze lasts only as long as AWS takes to
# accept the snapshot (state "pending"). The tags and the description match aws_ebs_snapshot.data in
# main.tf, so the import block adopts it with no diff; keep them in sync with locals.tags.
take() {
  local label="${1:?usage: take <label> [--no-freeze]}" want_freeze=yes volume left arn out
  frozen=no snap_id="" done_ok=no auto_thaw_at=0 create_tried=no
  [[ "${2:-}" == --no-freeze ]] && want_freeze=no
  [[ "$label" =~ ^[a-z0-9-]{1,20}$ ]] || die "label: lowercase letters, digits and '-', up to 20 characters"

  arn="$(aws sts get-caller-identity --query Arn --output text)"
  [[ "$arn" == *":assumed-role/terraform-lab-role/"* ]] || die "running as $arn; run aws-lab first"
  # aws-lab exports AWS_CREDENTIAL_EXPIRATION; credentials expiring mid-freeze would break the thaw.
  if [[ -n "${AWS_CREDENTIAL_EXPIRATION:-}" ]]; then
    left=$(( $(date -d "$AWS_CREDENTIAL_EXPIRATION" +%s) - $(date +%s) ))
    (( left > 900 )) || die "aws-lab session ends in $((left / 60)) min; run aws-lab again"
    echo "aws-lab session: $((left / 60)) min left"
  fi

  instance="$(terraform -chdir="$stack" output -raw instance_id)"
  volume="$(terraform -chdir="$stack" output -raw data_volume_id)"
  [[ "$(aws ec2 describe-snapshots --region "$region" --owner-ids self \
        --filters Name=tag:Lab,Values=ebs-snapshots Name=tag:SnapshotLabel,Values="$label" \
        --query 'length(Snapshots)')" == 0 ]] || die "a lab snapshot labelled $label already exists"
  [[ "$(aws ec2 describe-snapshots --region "$region" --owner-ids self \
        --filters Name=volume-id,Values="$volume" Name=status,Values=pending \
        --query 'length(Snapshots)')" == 0 ]] || die "$volume has a pending snapshot; a new one would stack behind it"
  [[ "$(aws ssm describe-instance-information --region "$region" \
        --filters Key=InstanceIds,Values="$instance" --query 'InstanceInformationList[0].PingStatus' \
        --output text)" == Online ]] || die "$instance is not Online in SSM"

  trap on_exit EXIT
  if [[ "$want_freeze" == yes ]]; then
    # Marked frozen before the call: if the freeze ran but its result got lost, the thaw still goes.
    frozen=yes
    ssm_run "$instance" "lab-ebs freeze 60"
    # The instance's timer started before ssm_run returned, so this is at or after its auto-thaw.
    auto_thaw_at=$(( $(date +%s) + 65 ))
  fi

  create_tried=yes
  out="$(aws ec2 create-snapshot --region "$region" --volume-id "$volume" \
    --description "Day 4 lab: data volume, snapshot $label" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Environment,Value=lab},{Key=Lab,Value=ebs-snapshots},{Key=Day,Value=4},{Key=ManagedBy,Value=terraform},{Key=Stack,Value=terraform/ebs-snapshots},{Key=Name,Value=lab-ebs-snap-$label},{Key=SnapshotLabel,Value=$label}]" \
    --query '[SnapshotId,State,StartTime]' --output text)"
  snap_id="${out%%[[:space:]]*}"
  echo "created: $out"

  if [[ "$frozen" == yes ]]; then
    unfreeze
  fi
  done_ok=yes
  echo
  echo "Add to terraform/ebs-snapshots/terraform.tfvars, then plan -out and inspect it (README step 3):"
  echo "  snapshots    = [..., \"$label\"]"
  echo "  snapshot_ids = { ..., $label = \"$snap_id\" }"
}

main() {
  case "${1:-status}" in
    status) status ;;
    blocks)
      first="${2:?usage: $0 blocks <snap-id> [second-snap-id]}"
      if [[ -n "${3:-}" ]]; then
        count_blocks list-changed-blocks --first-snapshot-id "$first" --second-snapshot-id "$3"
      else
        count_blocks list-snapshot-blocks --snapshot-id "$first"
      fi ;;
    take) shift; take "$@" ;;
    *) echo "usage: $0 status | blocks <snap-id> [second-snap-id] | take <label> [--no-freeze]" >&2; exit 1 ;;
  esac
}

# Sourcing it (tests) defines the functions without running anything.
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
