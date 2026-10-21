#!/usr/bin/env bash
# Wrapper: runs the Python (boto3) inventory in the project venv, creating it the first time.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)"
venv="$dir/.venv"

# The marker only exists once the venv is complete; a half-built venv is rebuilt.
if [[ ! -f "$venv/.pronto" ]]; then
  rm -rf "$venv"
  if ! python3 -m venv "$venv" >&2; then
    rm -rf "$venv"
    echo "ERROR: could not create the venv. Run: sudo apt install -y python3.14-venv" >&2
    exit 1
  fi
  "$venv/bin/pip" install -q -r "$dir/requirements.txt"
  touch "$venv/.pronto"
fi
exec "$venv/bin/python" -I "$dir/scripts/inventory.py"
