#!/usr/bin/env bash
# Wrapper: roda o inventário em Python (boto3) no venv do projeto, criando-o na primeira vez.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)"
venv="$dir/.venv"

# O marcador só existe depois que o venv ficou completo; um venv pela metade é refeito.
if [[ ! -f "$venv/.pronto" ]]; then
  rm -rf "$venv"
  if ! python3 -m venv "$venv" >&2; then
    rm -rf "$venv"
    echo "ERRO: não deu para criar o venv. Rode: sudo apt install -y python3.14-venv" >&2
    exit 1
  fi
  "$venv/bin/pip" install -q -r "$dir/requirements.txt"
  touch "$venv/.pronto"
fi
exec "$venv/bin/python" -I "$dir/scripts/inventario.py"
