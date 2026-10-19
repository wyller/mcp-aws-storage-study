#!/usr/bin/env bash
# SessionEnd: dispara o inventário em segundo plano (não segura o fechamento do Claude Code).
# O resultado é lido pelo hook de SessionStart na próxima sessão.
dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
estado="$dir/.claude/estado"
mkdir -p "$estado"

setsid nohup bash -c '
  out="$1/ultimo-inventario.txt"
  { echo "# inventário de $(date "+%Y-%m-%d %H:%M")"; "$2/scripts/inventario.sh"; } > "$out.tmp" 2>&1 \
    && mv "$out.tmp" "$out"
' _ "$estado" "$dir" >/dev/null 2>&1 < /dev/null &
exit 0
