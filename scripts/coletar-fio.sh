#!/usr/bin/env bash
# Copia os resultados do fio (/tmp/lab-fio-*.json e /tmp/lab-fase-*.log) da EC2 do lab para o repo,
# via SSM Run Command: sem SSH e sem bucket. Confere cada arquivo pelo sha256 calculado na EC2.
# ssm:SendCommand é escrita: rode no seu terminal, depois do aws-lab.
#   scripts/coletar-fio.sh i-0123456789abcdef0 [pasta-destino]
set -euo pipefail
instance="${1:?uso: scripts/coletar-fio.sh <instance-id> [pasta-destino]}"
dir="$(cd "$(dirname "$0")/.." && pwd)"
dest="${2:-$dir/notas/dados/ebs-dia1}"
region=us-east-1

# Na EC2 (roda como root, então lê os arquivos que o "sudo fio" criou): manifesto sha256, um
# marcador e o tar.gz em base64 numa linha só. A saída inline do SSM corta em 24.000 caracteres;
# se cortar, o tar ou o sha256 falham abaixo, nunca passa um arquivo pela metade.
remoto='cd /tmp && f=$(ls lab-fio-*.json lab-fase-*.log 2>/dev/null) && [ -n "$f" ] && sha256sum $f && echo ---TAR--- && tar czf - $f | base64 -w0'
params="$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$remoto")"

cmd_id="$(aws ssm send-command --region "$region" --instance-ids "$instance" \
  --document-name AWS-RunShellScript --comment "coleta fio do lab" \
  --parameters "$params" --query Command.CommandId --output text)"
echo "comando SSM $cmd_id enviado; esperando..." >&2
aws ssm wait command-executed --region "$region" --command-id "$cmd_id" --instance-id "$instance" || true

status="$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" \
  --query Status --output text)"
saida="$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" \
  --query StandardOutputContent --output text)"
if [[ "$status" != "Success" ]]; then
  echo "ERRO: comando terminou como $status (nenhum arquivo lab-fio-*.json / lab-fase-*.log em /tmp?)" >&2
  exit 1
fi
if (( ${#saida} >= 23900 )); then
  echo "AVISO: saída com ${#saida} caracteres, perto do corte de 24.000 do SSM" >&2
fi

mkdir -p "$dest"
printf '%s\n' "$saida" | sed '/^---TAR---$/,$d' > "$dest/SHA256SUMS"
printf '%s\n' "$saida" | sed '1,/^---TAR---$/d' | base64 -d | tar xzf - -C "$dest"

cd "$dest"
sha256sum -c SHA256SUMS
echo "OK: $(wc -l < SHA256SUMS) arquivo(s) em $dest, conferidos pelo sha256 da EC2" >&2
