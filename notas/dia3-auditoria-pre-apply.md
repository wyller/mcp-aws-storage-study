# S3: Dia 3. Auditoria antes do apply da replicação (2026-10-22)

Stack: `terraform/s3-replication/main.tf`. Região `us-east-1`, SRR (mesma região). Tudo abaixo foi **verificado** com o `readonly-user` (perfil default), só leitura. Nada foi aplicado nem alterado na AWS.

## Contexto

O `terraform-lab-role` não cria policies IAM e, até o Dia 2, só passava roles ao EC2. A replicação precisa de uma role que o S3 assume, então o usuário fez duas alterações manuais no console (passos 5 e 6 do `SETUP.md`):

1. criou a managed policy `lab-s3-replication` (`policies/lab-s3-replication.json`);
2. publicou a v2 da allow-list `terraform-lab-iam-lab-roles` (`policies/terraform-lab-iam-lab-roles.json`).

## Resultados

| # | Verificação | Comando | Resultado |
|---|---|---|---|
| 1 | `lab-s3-replication` existe | `aws iam get-policy` | ✅ v1, criada em 2026-10-22 12:22 UTC, 0 attachments (esperado antes do apply) |
| 2 | Documento efetivo | `aws iam get-policy-version` | ✅ 3 statements: bucket de origem (`GetReplicationConfiguration`, `ListBucket`), versões na origem (`GetObjectVersionForReplication`/`Acl`/`Tagging`) e réplicas no destino (`ReplicateObject`/`Delete`/`Tags`). Todas limitadas a `lab-s3-repl-src-*` / `lab-s3-repl-dst-*` e com `aws:ResourceAccount = 004009722521` |
| 3 | Allow-list com a nova versão como default | `aws iam list-policy-versions` | ✅ v2 é a default (2026-10-22 12:23 UTC); a v1 ficou como não-default |
| 4 | AWS × repo | comparação semântica dos JSON em Python | ✅ as duas policies batem com `policies/`. A AWS devolve o documento reformatado, então a igualdade é de conteúdo, não de bytes |
| 5 | Attachments do `terraform-lab-role` | `list-attached-role-policies`, `list-role-policies`, `get-role` | ✅ só `PowerUserAccess` + `terraform-lab-iam-lab-roles`; nenhuma inline policy, nenhum permissions boundary |
| 6 | Escopo do `iam:PassRole` | leitura da allow-list v2 e do `PowerUserAccess` v12 | ✅ ver abaixo |
| 7 | Terraform | `fmt -check`, `validate`, `plan` | ✅ fmt rc=0; ✅ validate OK; ✅ plan: **17 to add, 0 to change, 0 to destroy** |

Uma pegadinha durante a auditoria: o primeiro `diff <(jq -S ...)` devolveu "IDENTICAL", mas o `jq` não estava instalado. As duas entradas estavam vazias, então o diff comparou nada com nada. Um "igual" que vem de entradas vazias não prova nada; a comparação foi refeita em Python.

## `iam:PassRole`: de onde vem cada autorização

- O `PowerUserAccess` libera tudo **exceto** `iam:*` (via `NotAction`), e as exceções de IAM dele não incluem PassRole. Portanto, todo PassRole do `terraform-lab-role` vem da allow-list.
- A statement ampla `PassRoleSoParaEC2` (`role/lab-*`) está condicionada a `iam:PassedToService = ec2.amazonaws.com`. Ela só passa roles para o EC2. **Não autoriza nada para o S3.**
- A autorização para o S3 vem só da statement específica `PassRoleOnlyS3ReplicationToS3`: `role/lab-s3-repl-*` com `iam:PassedToService = s3.amazonaws.com`.
- Como `lab-*` também cobre `lab-s3-repl-*`, essas roles podem ser passadas ao EC2. Isso não tem efeito prático: a trust policy de `lab-s3-repl-role` só aceita `s3.amazonaws.com`.

## O que o plan cria (17)

- 2 buckets, `lab-s3-repl-src-004009722521` e `lab-s3-repl-dst-004009722521`, cada um com public access block, `BucketOwnerEnforced`, versioning, SSE-S3, lifecycle e bucket policy (`DenyInsecureTransport`). São 12 recursos.
- A role `lab-s3-repl-role` (trust só em `s3.amazonaws.com`) e o attachment de `lab-s3-replication`.
- A replication configuration: prefixo `repl/`, delete marker replication desligada, metrics ligadas.

Não há colisão: não existem buckets `lab-s3-repl*` nem a role `lab-s3-repl-role` na conta, e o diretório não tem state.

## Como cobra

- **Replicação SRR:** não tem transferência entre regiões. Paga storage nos dois buckets (cada réplica é uma cópia cheia) e as requests de PUT no destino.
- **Replication metrics:** são custom metrics do CloudWatch, cobradas por hora enquanto a regra existir, mesmo sem tráfego.
- **Lifecycle:** versões antigas expiram em 1 dia e multipart incompleto é abortado em 1 dia. Isso limita o storage se o destroy atrasar. Ações de lifecycle não replicam: cada bucket precisa das próprias regras.
- **IAM** (policies e roles): sem custo.

## Riscos operacionais

- **Destroy:** `force_destroy=false` por padrão. Com versioning, o `destroy` falha se houver versões ou delete markers. Antes, rodar `apply -var force_destroy=true`.
- **Nomes:** se um bucket sair dos prefixos `lab-s3-repl-src-*` / `-dst-*`, a replicação falha calada: a regra continua "Enabled" e o objeto fica `FAILED`.

## Melhorias futuras (permissões amplas, baixo risco hoje)

Hoje o risco é baixo: o `terraform-lab-role` exige MFA e só o usuário usa. Mesmo assim, ficam registradas:

1. **Trust policy livre em `lab-*`.** `iam:CreateRole` e `UpdateAssumeRolePolicy` aceitam qualquer trust. Dá para criar uma `lab-s3-repl-x` confiando em uma conta externa e anexar `lab-s3-replication`, que lê o conteúdo dos objetos de `lab-s3-repl-src-*` (`GetObjectVersionForReplication`). Melhoria: exigir um permissions boundary nas roles `lab-*` (condição `iam:PermissionsBoundary` no `CreateRole`).
2. **`lab-s3-replication` anexável a qualquer `lab-*`.** O `AttachRolePolicy` aceita a policy em qualquer role `lab-*` (ex.: `lab-storage-ec2-ssm`). Melhoria: separar a statement e limitar essa policy a `role/lab-s3-repl-*`.

## Próximos passos

1. O usuário roda `aws-lab` e `terraform apply` em `terraform/s3-replication`.
2. Validar: `get-bucket-replication`; PUT em `repl/` e fora dele; `x-amz-replication-status` (PENDING → COMPLETED na origem, REPLICA no destino); metrics no CloudWatch.
3. Cenários de falha: `deny_replicate_on_dst=true` (objeto vira FAILED), regra desligada (o que foi escrito nesse intervalo nunca replica) e delete markers.
4. `apply -var force_destroy=true`, `terraform destroy`, `scripts/inventory.sh`.
