#!/usr/bin/env bash
# Copies the fio results (/tmp/lab-fio-*.json and /tmp/lab-fase-*.log) from the lab EC2 to the repo,
# via SSM Run Command: no SSH and no bucket. Checks each file against the sha256 computed on the EC2.
# ssm:SendCommand is a write: run it in your terminal, after aws-lab.
#   scripts/collect-fio.sh i-0123456789abcdef0 [dest-dir]
set -euo pipefail
instance="${1:?usage: scripts/collect-fio.sh <instance-id> [dest-dir]}"
dir="$(cd "$(dirname "$0")/.." && pwd)"
dest="${2:-$dir/notas/dados/ebs-dia1}"
region=us-east-1

# On the EC2 (runs as root, so it reads the files "sudo fio" created): sha256 manifest, a
# marker and the base64 tar.gz on a single line. SSM inline output is cut at 24,000 characters;
# if it gets cut, tar or sha256 fail below, so a half file never gets through.
remoto='cd /tmp && f=$(ls lab-fio-*.json lab-fase-*.log 2>/dev/null) && [ -n "$f" ] && sha256sum $f && echo ---TAR--- && tar czf - $f | base64 -w0'
params="$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$remoto")"

cmd_id="$(aws ssm send-command --region "$region" --instance-ids "$instance" \
  --document-name AWS-RunShellScript --comment "collect lab fio results" \
  --parameters "$params" --query Command.CommandId --output text)"
echo "SSM command $cmd_id sent; waiting..." >&2
aws ssm wait command-executed --region "$region" --command-id "$cmd_id" --instance-id "$instance" || true

status="$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" \
  --query Status --output text)"
output="$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" \
  --query StandardOutputContent --output text)"
if [[ "$status" != "Success" ]]; then
  echo "ERROR: command ended as $status (no lab-fio-*.json / lab-fase-*.log files in /tmp?)" >&2
  exit 1
fi
if (( ${#output} >= 23900 )); then
  echo "WARNING: output has ${#output} characters, close to the SSM 24,000 cut" >&2
fi

mkdir -p "$dest"
printf '%s\n' "$output" | sed '/^---TAR---$/,$d' > "$dest/SHA256SUMS"
printf '%s\n' "$output" | sed '1,/^---TAR---$/d' | base64 -d | tar xzf - -C "$dest"

cd "$dest"
sha256sum -c SHA256SUMS
echo "OK: $(wc -l < SHA256SUMS) file(s) in $dest, checked against the EC2 sha256" >&2
