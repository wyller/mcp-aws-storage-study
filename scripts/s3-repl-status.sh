#!/usr/bin/env bash
# Replication status of one key (read-only: head-object and list-object-versions, works as readonly-user).
# Source: PENDING | COMPLETED | FAILED, or nothing (outside the filter, written before the rule, rule off).
# Destination: REPLICA, or 404 if it never arrived.
#   scripts/s3-repl-status.sh repl/hello.txt          # one shot
#   scripts/s3-repl-status.sh repl/hello.txt --wait   # polls the source until it leaves PENDING
set -euo pipefail
key="${1:?usage: scripts/s3-repl-status.sh <key> [--wait]}"
account="$(aws sts get-caller-identity --query Account --output text)"
src="lab-s3-repl-src-$account"
dst="lab-s3-repl-dst-$account"

head_obj() {
  aws s3api head-object --bucket "$1" --key "$key" \
    --query '{status: ReplicationStatus, version: VersionId, size: ContentLength, modified: LastModified}' \
    --output json 2>&1 | tr -d '\n ' || true
}

if [[ "${2:-}" == "--wait" ]]; then
  start=$(date +%s)
  # 15 min ceiling: without RTC there is no SLA, but in SRR small objects take seconds.
  while (( $(date +%s) - start < 900 )); do
    status="$(aws s3api head-object --bucket "$src" --key "$key" --query ReplicationStatus --output text 2>/dev/null || echo ERROR)"
    [[ "$status" != "PENDING" ]] && break
    sleep 2
  done
  echo "source left PENDING after ~$(( $(date +%s) - start ))s: $status"
fi

echo "src $src: $(head_obj "$src")"
echo "dst $dst: $(head_obj "$dst")"
echo "versions in src (key prefix match):"
aws s3api list-object-versions --bucket "$src" --prefix "$key" \
  --query '{versions: Versions[].[Key,VersionId,IsLatest], markers: DeleteMarkers[].[Key,VersionId,IsLatest]}' --output json
echo "versions in dst (key prefix match):"
aws s3api list-object-versions --bucket "$dst" --prefix "$key" \
  --query '{versions: Versions[].[Key,VersionId,IsLatest], markers: DeleteMarkers[].[Key,VersionId,IsLatest]}' --output json
