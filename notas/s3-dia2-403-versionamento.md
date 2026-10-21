# S3: Dia 2. O 403 de IAM contra bucket policy, e versionamento (2026-10-21)

Bucket `lab-s3-dia2-004009722521`, região `us-east-1`. Código: `terraform/s3/main.tf`. Evidências brutas, lidas com o `readonly-user`: [`dados/s3-dia2/`](dados/s3-dia2/).

**Sobre as evidências:** os testes E1 a E4, o de delete marker e a avaliação rodaram no terminal do usuário, e as saídas brutas não foram copiadas para o repo. Esta nota marca cada item como **verificado** (lido na AWS, ou no state e no código, e salvo em `dados/s3-dia2/`) ou **relatado** (feito pelo usuário, sem a saída aqui).

## Setup

| Item | Config |
|---|---|
| Bucket | privado, Block Public Access com os 4 em `true`, `BucketOwnerEnforced` (ACLs desligadas), versionamento `Enabled`, SSE-S3 (AES256, sem KMS) |
| Bucket policy | `DenyInsecureTransport` (nega `aws:SecureTransport=false`) e `DenyRestrictedToReadonly` (nega `s3:GetObject`/`GetObjectVersion` em `restricted/*` ao `readonly-user`). Opcional: `DenyListToReadonly`, pela variável `deny_list_to_readonly` |
| Objetos do Terraform | `public/hello.txt` (44 B) e `restricted/hello.txt` (63 B) |
| Identidades | **cliente:** `readonly-user` (`ReadOnlyAccess`: `s3:Get*`, `s3:List*`). **admin:** `terraform-lab-role` (`aws-lab`) |
| Tags | `Environment=lab`, `Project=storage-study`, `Day=2-s3` |

Sem EC2, KMS, NAT ou VPC endpoint. A `lab-s3-read-role` não entrou: o trust dela só aceita `ec2.amazonaws.com`, e a `terraform-lab-role` não pode dar permissão S3 a uma role nova (não tem `PutRolePolicy`, e o `AttachRolePolicy` só aceita a `AmazonSSMManagedInstanceCore`). O cenário inteiro foi montado na bucket policy, sem tocar em IAM.

A AWS colocou `BlockedEncryptionTypes: SSE-C` na criptografia do bucket sozinha. Isso não está no Terraform. Bucket novo recusa upload com chave do cliente.

## IAM contra bucket policy: Allow e Deny explícito (relatado)

| Teste | Identidade | Chamada | Resultado esperado (assinatura) |
|---|---|---|---|
| E1 | `readonly-user` | `get-object public/hello.txt` | 200: o IAM permite e nada nega |
| E2 | `readonly-user` | `get-object restricted/hello.txt` | 403 `... with an explicit deny in a resource-based policy` |
| E2 | `terraform-lab-role` | `get-object restricted/hello.txt` | 200: o deny vale só para aquele principal |
| E3 | `readonly-user` | `put-object` | 403 `... because no identity-based policy allows the s3:PutObject action` |

Regra da mesma conta: o acesso é liberado se o IAM **ou** a bucket policy permitir, e **nenhum** dos dois negar. Deny explícito sempre vence. A mensagem do 403 já diz o lado: "explicit deny in a resource-based policy" (bucket policy) ou "no identity-based policy allows" (falta permissão no IAM) ([docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/troubleshoot-403-errors.html)). Para confirmar sem fazer a requisição: `aws iam simulate-principal-policy ... --resource-policy "$(aws s3api get-bucket-policy ...)"`.

### Um 403 real fora do roteiro (verificado)

O `terraform plan` como `readonly-user`, com os objetos já no bucket, abortou no refresh:

```
Error: reading S3 Object (lab-s3-dia2-004009722521/restrito/ola.txt): operation error S3: HeadObject,
https response error StatusCode: 403, RequestID: T9H7EQBR64R2TVGK, ..., api error Forbidden: Forbidden
```

O mesmo erro apareceu no terminal do usuário (RequestID `K94YYAX7JZK61WVQ`). Lá, o `sts get-caller-identity` mostrou `readonly-user`: o `aws-lab` não estava ativo naquela aba. Depois do `aws-lab`, o plan deu 2 to add, 3 to change, 2 to destroy, e o apply passou.

- O refresh do Terraform faz `HeadObject`, que exige `s3:GetObject`. Por isso o Deny da bucket policy atinge até o Terraform, quando ele roda com o principal negado.
- **HEAD devolve só `Forbidden`, sem o motivo**, porque não tem corpo. Para ler a mensagem, use `get-object`.
- O plan abortado mostrava um resumo parcial ("1 to destroy" em vez de 2). Plan com erro não vale como plan.
- Para revisar este stack como `readonly-user`, use `terraform plan -refresh=false`.
- **Primeiro comando de qualquer AccessDenied:** `aws sts get-caller-identity`, **no mesmo terminal** da chamada que falhou. O `!` do Claude Code roda em outra sessão e não prova nada sobre a aba do usuário.

## 403 contra 404 conforme o `s3:ListBucket` (relatado, com apoio no CloudTrail)

| Teste | `s3:ListBucket` | `get-object nao-existe.txt` |
|---|---|---|
| E4a | permitido (`ReadOnlyAccess`) | 404 `NoSuchKey` |
| E4b | negado (`-var deny_list_to_readonly=true`) | **403** `AccessDenied` |

Sem `ListBucket`, o S3 não revela se a chave existe, e o 404 vira 403 ([docs](https://repost.aws/knowledge-center/s3-static-website-endpoint-error)). Num 403 em objeto, confira também se o objeto existe, com uma identidade que tenha `ListBucket`.

O CloudTrail tem `PutBucketPolicy` às **11:44:17** e às **11:50:42 UTC**, depois do apply da tradução (11:14:21). O horário bate com o apply de `deny_list_to_readonly=true` e com a reversão. A policy atual voltou a ter só `DenyInsecureTransport` e `DenyRestrictedToReadonly` ([`bucket-policy.json`](dados/s3-dia2/bucket-policy.json)). Os `GetObject` negados não aparecem: são data events, desligados por padrão e cobrados à parte.

## Versionamento, delete marker e recuperação

### Delete marker (relatado)

`delete-object` sem `--version-id` não apaga nada. Ele cria um delete marker, que vira a versão atual: o `get-object` passa a dar 404, e as versões continuam lá, cobrando. Para recuperar, há dois caminhos: ler com `--version-id`, ou apagar o próprio marker com `delete-object --version-id <id-do-marker>`. Nesse caso o objeto "volta" ([docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html)).

No fim do dia, `DeleteMarkers` estava `null` ([`list-object-versions.json`](dados/s3-dia2/list-object-versions.json)). Isso é consistente com o marker ter sido removido pelo `version-id`, mas o estado atual não prova que ele existiu.

### Recuperação depois de uma sobrescrita incorreta (verificado)

Versões de `versioning/relatorio.txt` (UTC):

| # | VersionId | LastModified | Tamanho | ETag | Leitura |
|---|---|---|---|---|---|
| 1 | `QubBNt0m…` | 11:53:27 | 32 B | `b5fb0dcc…` | primeira versão |
| 2 | `F66JNRSm…` | 11:54:02 | 32 B | `0a2cc0b0…` | **versão válida** |
| 3 | `54OYrPS1…` | 12:29:10 | 50 B | `46a63390…` | sobrescrita incorreta |
| 4 | `KrxDQGvF…` | 12:32:29 | 32 B | `0a2cc0b0…` | atual (`IsLatest`): **mesmo ETag da versão 2** |

A recuperação não apagou a versão errada. Ela criou uma **versão nova** com o conteúdo da versão 2: o ETag é igual (num upload simples com SSE-S3, o ETag é o MD5 do conteúdo), e o tamanho também. O histórico inteiro ficou: dá para auditar o que foi gravado errado e quando. O comando exato não foi registrado. O resultado é consistente com um `copy-object --copy-source "<bucket>/versioning/relatorio.txt?versionId=F66JNRSm…"`.

Por que copiar em vez de apagar a versão 3: apagar com `--version-id` também "volta" a versão anterior, mas destrói a evidência e exige `s3:DeleteObjectVersion`. Copiar só exige `GetObjectVersion` e `PutObject`.

### Terraform e versões (verificado)

Na tradução, o apply trocou `publico/ola.txt` e `restrito/ola.txt` por `public/` e `restricted/`. Os objetos antigos sumiram por completo, sem versões e sem delete marker: ao destruir um `aws_s3_object`, o provider apaga **todas as versões daquela chave**. Um `aws s3 rm` ou um delete pelo console deixaria um marker e as versões cobrando.

## Auditoria do Lifecycle (verificado)

| Regra | Filtro | Ação |
|---|---|---|
| `expire-old-versions` | bucket todo | `NoncurrentVersionExpiration`: 1 dia; `ExpiredObjectDeleteMarker: true` |
| `abort-multipart` | bucket todo | `AbortIncompleteMultipartUpload`: 1 dia |

A API devolve `TransitionDefaultMinimumObjectSize: all_storage_classes_128K`, que não está no Terraform. É o padrão da AWS: objetos com menos de 128 KiB não fazem transição de classe. Não afeta este lab, que não tem transição. Mas num lifecycle de IA ou Glacier, os objetos pequenos ficariam no Standard ([`lifecycle.json`](dados/s3-dia2/lifecycle.json)).

**Consequência para o versionamento:** as versões 1 a 3 de `relatorio.txt` estão noncurrent. O lifecycle as expira 1 dia depois de ficarem noncurrent, então o histórico da recuperação **não sobrevive** até amanhã. Para um histórico de auditoria, `noncurrent_days` precisa ser maior. A regra de 1 dia aqui é só uma rede de segurança de custo.

### Exercício: `noncurrent_days = 1 -> 30` só com plan (relatado, com apoio no CloudTrail)

O código foi alterado para `noncurrent_days = 30`, rodou-se só o `terraform plan`, e o código voltou para 1 sem apply. A saída do plan não foi guardada. O esperado é um update in-place no `aws_s3_bucket_lifecycle_configuration`, sem replace. O CloudTrail confirma que não houve apply: os dois únicos `PutBucketLifecycle` do dia são 10:41:36 (criação) e 11:14:21 (tradução) ([`cloudtrail-management-events.txt`](dados/s3-dia2/cloudtrail-management-events.txt), horários em -03:00). A AWS continua com `NoncurrentDays: 1`, e o `main.tf` também.

## Validação final (verificado em 2026-10-21, ~13:10 UTC)

- `terraform validate`: `Success! The configuration is valid.`
- `terraform plan -refresh=false` (como `readonly-user`): `No changes. ... found no differences`.
- O usuário relatou o próprio `terraform plan` com `No changes`.

## Avaliação teórica

**10/10** (relatado). As questões não estão no repo.

## Como cobra

| Item | Como cobra | Neste lab |
|---|---|---|
| Armazenamento | GB-mês por classe (Standard ~US$ 0,023/GB-mês em us-east-1). **Cobra parado, e cada versão noncurrent conta como objeto inteiro** | ~300 B no total: ~US$ 0 |
| Requisições | PUT/COPY/LIST ~US$ 0,005 por 1.000; GET ~US$ 0,0004 por 1.000. Requisição negada também pode ser cobrada | centenas: < US$ 0,01 |
| Por hora | nada | US$ 0 |
| Delete marker | entra no armazenamento só pelo tamanho do nome da chave, mas esconde versões que cobram inteiras | — |

Preços: https://aws.amazon.com/s3/pricing/

## Outros achados

- **O inventário nunca contou bucket S3.** O client era criado com a região `"global"`, que monta o endpoint inexistente `s3.global.amazonaws.com`. O `EndpointConnectionError` estava na lista de erros ignorados (a de serviço indisponível numa região), então a checagem virava 0. Com o bucket na conta, o inventário dizia `LIMPO`. Corrigido em `89a2506` (`ListBuckets` em us-east-1 lista todas as regiões). Os "LIMPO" de antes não cobriam S3.
- **Código migrado para inglês** (`1e579b2`), como teste de estudo. Os `notas/` continuam em português. A tag `pt-br` marca o estado anterior.

## Limpeza (pendente)

O bucket ainda existe, com 6 versões. `versioning/relatorio.txt` foi criado pela CLI e está fora do state, então o `terraform destroy` vai falhar com `BucketNotEmpty` até ele ser esvaziado. O caminho:

1. `terraform plan -destroy -refresh=false` como `readonly-user`, para conferir o que sai.
2. Esvaziar as versões que estão fora do state (`list-object-versions` → `delete-objects`). A alternativa é `terraform apply -var force_destroy=true`.
3. `terraform destroy` com `aws-lab`.
4. `scripts/inventory.sh`, que agora conta S3, deve dar `CLEAN`.

## Próximo

- Se houver tempo: os 403 que ficaram fora (KMS sem `kms:Decrypt`, e a endpoint policy de um gateway endpoint de S3), o que exige EC2.
- Lifecycle de transição para IA e Glacier, com a duração mínima e o mínimo de 128 KiB.
