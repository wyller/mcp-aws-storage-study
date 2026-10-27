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

# freeze -> CreateSnapshot -> thaw from one place, so the freeze lasts only as long as AWS takes to
# accept the snapshot (state "pending"). The tags and the description match aws_ebs_snapshot.data in
# main.tf, so the import block adopts it with no diff; keep them in sync with locals.tags.
take() {
  local label="${1:?usage: take <label> [--no-freeze]}" freeze=yes instance volume left arn snap thaw_out
  [[ "${2:-}" == --no-freeze ]] && freeze=no
  [[ "$label" =~ ^[a-z0-9-]{1,20}$ ]] || die "label: lowercase letters, digits and '-', up to 20 characters"

  arn="$(aws sts get-caller-identity --query Arn --output text)"
  [[ "$arn" == *":assumed-role/terraform-lab-role/"* ]] || die "running as $arn; run aws-lab first"
  # aws-lab exports AWS_CREDENTIAL_EXPIRATION; a session that ends mid-freeze leaves it to the auto-thaw.
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

  if [[ "$freeze" == yes ]]; then
    # 60 s auto-thaw on the instance covers this script dying, or the network, between the two calls.
    ssm_run "$instance" "lab-ebs freeze 60"
    trap 'ssm_run "$instance" "lab-ebs thaw" >&2 || echo "WARNING: thaw failed; the auto-thaw runs within 60 s" >&2' EXIT
  fi

  snap="$(aws ec2 create-snapshot --region "$region" --volume-id "$volume" \
    --description "Day 4 lab: data volume, snapshot $label" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Environment,Value=lab},{Key=Lab,Value=ebs-snapshots},{Key=Day,Value=4},{Key=ManagedBy,Value=terraform},{Key=Stack,Value=terraform/ebs-snapshots},{Key=Name,Value=lab-ebs-snap-$label},{Key=SnapshotLabel,Value=$label}]" \
    --query '[SnapshotId,State,StartTime]' --output text)"

  if [[ "$freeze" == yes ]]; then
    thaw_out="$(ssm_run "$instance" "lab-ebs thaw")"
    trap - EXIT
    echo "$thaw_out"
  fi
  echo "created: $snap"
  echo
  echo "Add to terraform/ebs-snapshots/terraform.tfvars, then plan (expect: 1 to import, 0 to add):"
  echo "  snapshots    = [..., \"$label\"]"
  echo "  snapshot_ids = { ..., $label = \"${snap%%[[:space:]]*}\" }"
}

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
