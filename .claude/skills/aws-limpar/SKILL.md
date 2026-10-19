---
name: aws-limpar
description: Limpa a conta AWS de estudos (004009722521) no fim do dia com aws-nuke — dry-run, confirmação do usuário, execução e relatório do que sobrou. Use quando o usuário disser /aws-limpar, "limpar a conta", "apagar tudo da AWS", "não quero gastar à toa".
disable-model-invocation: true
---

# Limpar a conta AWS de estudos

Apaga tudo na conta `004009722521`, em todas as regiões, menos o que está protegido em `nuke-config.yaml` (acesso humano, budget, VPCs default). Usa a `claude-cleanup-role`, que só tem permissão para apagar.

Nunca pule a confirmação, nem quando o dry-run vier pequeno.

## 1. Pré-checagens

Rode e confira:

```bash
aws sts get-caller-identity --query Account --output text   # 004009722521
aws iam list-account-aliases --query 'AccountAliases[0]' --output text   # wyller-estudos
aws-nuke version
```

Se a conta ou o alias não baterem, **pare** e avise o usuário.

## 2. Dry-run

```bash
aws-nuke run --config nuke-config.yaml --profile default \
  --assume-role-arn arn:aws:iam::004009722521:role/claude-cleanup-role \
  --quiet --log-format json > .claude/estado/nuke-dry-run.jsonl 2>&1
```

O dry-run é o padrão do aws-nuke, então ele não apaga nada. Leia o arquivo e resuma pro usuário:

- uma tabela **região → tipo → quantidade** do que *seria removido*
- destaque o que custa por hora: EC2, NAT Gateway, Elastic IP, load balancers, RDS, FSx, Transfer, Storage Gateway, VPC endpoints de interface
- IAMRole e IAMInstanceProfile com nome `lab-*` são recursos de lab (criados pelo Terraform) e podem ir
- qualquer outro item de IAM (IAMUser, IAMRole, IAMPolicy, MFA) ou budget, **pare**: o filtro está errado. A policy da role nega mexer em IAM fora de `lab-*`, mas o dry-run não sabe disso

Se não houver nada a remover, diga isso e encerre.

## 3. Confirmação

Pergunte com AskUserQuestion: "Apagar os N recursos listados?", com as opções **Apagar** e **Cancelar**. Só siga com "Apagar".

## 4. Execução

```bash
aws-nuke run --config nuke-config.yaml --profile default \
  --assume-role-arn arn:aws:iam::004009722521:role/claude-cleanup-role \
  --no-dry-run --no-prompt --quiet --max-wait-retries 20 \
  --log-format json > .claude/estado/nuke-run.jsonl 2>&1
```

O harness também pede aprovação aqui (`--no-dry-run` está em `ask`). A execução pode levar vários minutos, e alguns recursos (NAT Gateway, FSx, RDS) demoram para apagar.

## 5. Relatório

1. Rode `scripts/inventario.sh` e salve a saída em `.claude/estado/ultimo-inventario.txt`, com `# inventário de <data>` na primeira linha.
2. Liste os recursos que **falharam** no `nuke-run.jsonl`, com o motivo. Causas comuns:
   - **AccessDenied:** a ação não está na `policies/claude-cleanup-delete-only.json`. Diga qual ação falta. Quem decide se entra é o usuário, e quem atualiza a policy no console é ele.
   - **Glacier vault não vazio:** apagar os arquivos exige um job de inventário (cerca de 24h). Explique isso e deixe para o usuário.
   - **S3 com Object Lock em modo compliance:** não dá para apagar antes do prazo de retenção.
   - **KMS:** a chave fica em `PendingDeletion` por 7–30 dias e não cobra nesse período.
3. Termine com uma linha: **conta limpa**, ou **sobrou X: precisa de ação manual**.
