#!/usr/bin/env bash
# SessionStart: injeta no contexto do Claude o último inventário de recursos que custam,
# e dispara um novo em segundo plano para a próxima vez.
dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
inv="$dir/.claude/estado/ultimo-inventario.txt"

if [[ -f "$inv" ]]; then
  if grep -qx "LIMPO" "$inv"; then
    echo "Inventário AWS: conta limpa no último fechamento de sessão ($(head -1 "$inv" | sed 's/^# //'))."
  else
    echo "ATENÇÃO — recursos AWS que podem estar custando (avise o usuário logo no início e sugira /aws-limpar):"
    cat "$inv"
  fi
else
  echo "Inventário AWS: ainda não há inventário salvo (rode scripts/inventario.sh para ver o estado atual)."
fi

echo "Para criar recursos (Terraform/CLI): rode aws-lab no seu terminal; pede o MFA e vale 1h. aws-lab-off volta ao readonly."

"$dir/scripts/hook-session-end.sh"
exit 0
