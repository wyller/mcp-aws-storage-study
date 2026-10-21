#!/usr/bin/env bash
# SessionEnd: starts the inventory in the background (doesn't hold up Claude Code's exit).
# The SessionStart hook reads the result in the next session.
dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
state="$dir/.claude/state"
mkdir -p "$state"

setsid nohup bash -c '
  out="$1/last-inventory.txt"
  { echo "# inventory of $(date "+%Y-%m-%d %H:%M")"; "$2/scripts/inventory.sh"; } > "$out.tmp" 2>&1 \
    && mv "$out.tmp" "$out"
' _ "$state" "$dir" >/dev/null 2>&1 < /dev/null &
exit 0
