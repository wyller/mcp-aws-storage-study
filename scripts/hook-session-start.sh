#!/usr/bin/env bash
# SessionStart: injects the last inventory of billable resources into Claude's context,
# and starts a new one in the background for next time.
dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
inv="$dir/.claude/state/last-inventory.txt"

if [[ -f "$inv" ]]; then
  if grep -qx "CLEAN" "$inv"; then
    echo "AWS inventory: account clean at the last session close ($(head -1 "$inv" | sed 's/^# //'))."
  else
    echo "WARNING — AWS resources that may be costing money (tell the user right at the start and suggest /aws-cleanup):"
    cat "$inv"
  fi
else
  echo "AWS inventory: no saved inventory yet (run scripts/inventory.sh to see the current state)."
fi

echo "To create resources (Terraform/CLI): run aws-lab in your terminal; it asks for MFA and lasts 4h. aws-lab-off goes back to readonly."

"$dir/scripts/hook-session-end.sh"
exit 0
