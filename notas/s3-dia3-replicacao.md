# S3: Dia 3. Replicação SRR, primeiro teste (2026-10-22)

Stack: `terraform/s3-replication/main.tf`. Auditoria de antes do apply: [`dia3-auditoria-pre-apply.md`](dia3-auditoria-pre-apply.md).

- **Verificado:** lido na AWS com o `readonly-user`.
- **Relatado:** feito pelo usuário com `aws-lab`; a saída não está no repo.

## Apply (relatado; estado verificado)

O usuário rodou `terraform apply` às 12:43 UTC. A conferência depois do apply (verificado):

| Hipótese | Comando | Resultado |
|---|---|---|
| Buckets em `us-east-1` | `list-buckets`, `get-bucket-location` | src e dst criados; location `None` = `us-east-1` |
| Versioning nos dois | `get-bucket-versioning` | `Enabled` / `Enabled` |
| Regra | `get-bucket-replication` | `repl-prefix`, `Enabled`, filtro `repl/`, destino STANDARD, metrics `Enabled`, delete markers `Disabled` |
| Role | `get-role`, `list-attached-role-policies` | trust só `s3.amazonaws.com`; só `lab-s3-replication`, nenhuma inline |
| AWS igual ao código | `terraform plan` | "No changes"; 21 itens no state (17 recursos + 4 data sources) |

## Teste 1: dentro e fora do filtro

PUTs (relatado), com `aws-lab`:

```bash
aws s3api put-object --bucket lab-s3-repl-src-004009722521 --key repl/a.txt  --body /tmp/t.txt
aws s3api put-object --bucket lab-s3-repl-src-004009722521 --key outro/b.txt --body /tmp/t.txt
```

Resultado (verificado, `head-object` e `list-object-versions`, ~1 min depois):

| Objeto | Origem: `ReplicationStatus` | Destino | VersionId | ETag | LastModified |
|---|---|---|---|---|---|
| `repl/a.txt` | `COMPLETED` | `REPLICA` | `CrXx1XvmEqVRdAnGeZFYWWnXD.4QqN4h` nos dois | `6250e933…` nos dois | 12:47:56 nos dois |
| `outro/b.txt` | sem status (`null`) | ausente | `NxNYiC7E…` (só na origem) | — | 12:48:07 |

### O que isso ensina

- **O status fica nos dois lados, com significados diferentes.**
  - Na origem ele mostra o andamento: `PENDING` → `COMPLETED`, ou `FAILED`.
  - No destino é sempre `REPLICA`.
  - Objeto **sem status** significa que a regra nem o avaliou: fora do filtro, ou escrito antes de a regra existir.
- **A réplica é uma cópia fiel, não um PUT novo.** Ela mantém o mesmo VersionId, o mesmo ETag e o mesmo `LastModified` da origem. Comparar o VersionId é o jeito mais rápido de provar que um objeto no destino veio da replicação.
- **Diagnóstico de `FAILED`, nesta ordem:**
  1. falta permissão na policy da role;
  2. o destino nega na bucket policy;
  3. o objeto está criptografado com KMS sem permissão na role.

  Neste lab o objeto usa SSE-S3 (AES256), então a terceira não se aplica.

## Metrics no CloudWatch (verificado)

Dimensões: `SourceBucket`, `DestinationBucket` e `RuleId=repl-prefix`. Consulta: `get-metric-statistics`, período de 60 s, `Maximum`.

| Minuto (UTC) | `ReplicationLatency` (s) | `OperationsPendingReplication` | `BytesPendingReplication` |
|---|---|---|---|
| 12:45 a 12:47 | 0 | 0 | 0 |
| 12:48 | **5** | **1** | **37** |

- **O pico está em 12:48, não em 12:47.** O PUT de `repl/a.txt` foi às 12:47:56; o datapoint de 12:48 mostra 1 operação pendente de 37 B (o tamanho do objeto), replicada com latência de 5 s.
- **`OperationsFailedReplication` não apareceu.** Ela só começou a ser publicada no incidente do teste 2 (abaixo); sem falha, a ausência dela é o esperado.
- **Atraso:** às 12:49 ainda não havia datapoints; eles apareceram até as 12:54. Na primeira leitura, `list-metrics` listou só uma das métricas e depois nenhuma. Durante esse atraso, o `list-metrics` oscila. Num incidente, não conclua nada de metrics com menos de ~5 min.
- **Antes do primeiro PUT**, as métricas já publicavam zero: a regra gera datapoints mesmo sem tráfego. É isso que cobra estando parado.

## Como cobra (o que está rodando agora)

- **Storage:** 2 × 37 B (objeto replicado) + 37 B (fora do filtro). Desprezível. Cada réplica é uma cópia cheia: replicar dobra o storage do que passa pelo filtro.
- **Requests:** o PUT da réplica no destino é cobrado como request normal. SRR não tem transferência entre regiões.
- **Metrics:** custom metrics do CloudWatch, cobradas por hora enquanto a regra existir, **mesmo sem tráfego**. É o que custa estando parado.

## Incidente provocado: Explicit Deny no destino (teste 2)

Todos os horários estão em UTC. Na saída do CloudWatch eles vêm em -03.

### Linha do tempo

| Hora | Evento | Fonte |
|---|---|---|
| ~13:12 | `terraform plan -var='deny_replicate_on_dst=true' -out=deny.tfplan`; `apply deny.tfplan` (0 add, 1 change, 0 destroy) | relatado; o plan com o `readonly-user` foi verificado antes |
| 13:15:45 | PUT de `repl/falha-deny-dia3.txt` (41 B, VersionId `B_N1Mb.qGYe2uW3me0tDlq7OmMLz8j8k`) | verificado |
| 13:15–13:16 | mesmo VersionId: `PENDING` → `FAILED` | relatado (capturas do console) |
| 13:16 | metrics: 1 operação pendente, 41 B, `ReplicationLatency` 16 s | verificado |
| 13:17 | `OperationsFailedReplication` = 1 | verificado |
| 13:19:42 | `plan -var='deny_replicate_on_dst=false' -out=undo.tfplan`; `apply undo.tfplan` (rollback) | relatado; o horário vem do state |
| 13:21:28 | PUT de `repl/recuperacao-dia3.txt` (42 B), depois do rollback | verificado |

### Causa

A v2 da bucket policy do destino ganhou esta statement:

```json
{
  "Sid": "DenyReplicationRole",
  "Effect": "Deny",
  "Principal": { "AWS": "arn:aws:iam::004009722521:role/lab-s3-repl-role" },
  "Action": "s3:ReplicateObject",
  "Resource": "arn:aws:s3:::lab-s3-repl-dst-004009722521/*"
}
```

O IAM da role (`lab-s3-replication`) permite `s3:ReplicateObject` no destino, mas um Deny explícito na resource policy vence qualquer Allow. O S3 assumiu a role, teve a gravação da réplica negada e marcou a versão como `FAILED`.

### Diagnóstico: o que mostrava a falha e o que escondia

| Sinal | Valor durante a falha | Mostra o problema? |
|---|---|---|
| `get-bucket-replication` | regra `Enabled` | **não**: a configuração parece saudável |
| policy IAM da role | Allow em `ReplicateObject` | **não**: o lado IAM está correto |
| `head-object` na origem | `ReplicationStatus: FAILED` | sim, por objeto |
| `head-object` no destino | 404 | sim, por objeto |
| `OperationsFailedReplication` | 1 às 13:17 | sim, por regra; dá para alarmar. Chega com atraso de minutos |
| `get-bucket-policy` no destino | `DenyReplicationRole` presente | é a causa |

O caminho de diagnóstico, do sintoma à causa:
1. **Status `FAILED` no objeto:** o problema existe e é por objeto.
2. **Regra e IAM da role em ordem:** isso afasta config e identity policy.
3. **Olhar o outro lado, a resource policy do destino:** Deny explícito para a role.

É o mesmo raciocínio do 403 do Dia 2: quando o IAM permite e a operação falha, o próximo lugar a olhar é a resource policy.

A `OperationsFailedReplication` não tinha datapoints às 13:20, mas tinha às 13:22. O atraso de ~5 min se repetiu.

**A falha está confirmada por dois sinais independentes:**
1. `ReplicationStatus=FAILED` no `head-object` da versão `B_N1Mb.qGYe2uW3me0tDlq7OmMLz8j8k` na origem. É o sinal por objeto.
2. `OperationsFailedReplication = 1` às 13:17 (dimensões `SourceBucket`, `DestinationBucket`, `RuleId=repl-prefix`). É o sinal agregado por regra, onde se pendura um alarme.

Os dois apontam para o mesmo evento: 1 objeto, no mesmo minuto em que `BytesPendingReplication` registrou 41 B, o tamanho do objeto.

### Rollback e verificação (verificado às 13:22–13:23)

| Verificação | Resultado |
|---|---|
| `get-bucket-policy` no destino | só `DenyInsecureTransport`; `DenyReplicationRole` foi removida |
| `terraform plan` sem `-var` | `No changes` |
| `repl/recuperacao-dia3.txt` | origem `COMPLETED`, destino `REPLICA`, mesmo VersionId (`Lm8azZfVwXodH8ZwW7cV.sB6taZ07vQT`) e mesmo ETag (`245681cc…`) |
| `repl/a.txt` (teste 1) | continua `COMPLETED` / `REPLICA`; o Deny não afetou o que já tinha sido replicado |
| `repl/falha-deny-dia3.txt` | continua **`FAILED`** na origem e ausente no destino (404) |

### O objeto que falhou não se recupera sozinho

Tirar o Deny só conserta as gravações novas. A replicação normal não reprocessa versões `FAILED` ([re:Post](https://repost.aws/knowledge-center/s3-troubleshoot-replication)). Opções:

| Opção | Como | Efeito | Neste lab |
|---|---|---|---|
| Regravar | `copy-object` do objeto sobre ele mesmo, com `--metadata-directive REPLACE` | cria um VersionId novo, que replica; a versão `FAILED` vira noncurrent | viável |
| S3 Batch Replication | job com filtro de status `Failed` ([docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-batch-replication-batch.html)) | replica a **versão original**, com o mesmo VersionId | bloqueada: precisa de uma role para `batchoperations.s3.amazonaws.com`, e o `terraform-lab-role` só passa roles ao EC2 e ao S3. Cobra por job e por objeto |
| Aceitar | nada | a versão expira pelo lifecycle (noncurrent em 1 dia; esta é a current, então fica até ser sobrescrita ou apagada) | aceitável para objeto de teste |

**Decisão (2026-10-22):** `repl/falha-deny-dia3.txt` fica na origem, sem regravar, como evidência do incidente até a limpeza final do Dia 3 (`force_destroy=true` + `destroy`).

Lição para produção: depois de corrigir a causa, **sempre** rode um levantamento de `FAILED`, por S3 Inventory ou por Batch Replication com filtro. Senão, o dado que falhou durante o incidente fica para sempre fora do destino, sem nenhum alarme novo.

## Delete markers (testes 3 e 4)

DELETE sem `--version-id` feito pelo usuário com `aws-lab` (relatado). Estado lido com `list-object-versions` às 13:45 (verificado).

| | Teste 3: `DeleteMarkerReplication=Disabled` | Teste 4: `Enabled` |
|---|---|---|
| Chave | `repl/delete-marker-dia3.txt` | `repl/delete-marker-dia3-on.txt` (chave nova: ligar a opção não replica markers que já existem) |
| PUT / DELETE | 13:36:51 / 13:37:24 | 13:40:49 / 13:42:25 |
| Origem | versão `oGekxKss…` noncurrent + marker `xaL_bwjr…` `IsLatest` → GET 404 | versão `6mkmjOR4…` noncurrent + marker `a4.14CF2…` `IsLatest` → GET 404 |
| Destino | versão `oGekxKss…` **`IsLatest`, sem marker** → GET 200 | versão `6mkmjOR4…` noncurrent + **o mesmo marker `a4.14CF2…`** → GET 404 |
| Leitura | o marker ficou só na origem; o destino continua servindo o objeto | o marker replicou com o mesmo VersionId; o objeto parece apagado nos dois buckets |

Sequência no Terraform (plans salvos, relatado): `dm-on.tfplan` (13:40, `Disabled` → `Enabled`), teste 4, `dm-off.tfplan` (13:44, rollback para `Disabled`). A regra com `Disabled` foi verificada às 13:45.

### O que isso ensina

- **V2 (`Filter` na regra) não replica delete marker por padrão.** O destino funciona como proteção contra DELETE acidental na origem, mas os dois lados deixam de estar em sincronia ([docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-what-is-isnot-replicated.html)).
- **`DeleteMarkerReplication=Enabled`** mantém os dois lados iguais: um DELETE na origem esconde o objeto também no destino. Os dados continuam lá como versão noncurrent; nada foi apagado de verdade.
- **O que nunca replica, com qualquer configuração:**
  - DELETE **com** `--version-id`: apagar uma versão de vez não chega ao destino. É a proteção contra exclusão maliciosa.
  - Markers criados por lifecycle.
  - Markers em regras com filtro por **tag**, que não aceitam a opção.
- **"Desapagar" com a opção ligada** é apagar o marker pelo VersionId em **cada** bucket: esse DELETE tem version-id, então não replica.
- **Pergunta de entrevista:** "apaguei na origem e o objeto continua no DR, está quebrado?" Não. É o comportamento padrão da V2. Para espelhar exclusões, ligue `DeleteMarkerReplication`, e aí aceite que um erro humano também é espelhado.

## Encerramento (verificado às 13:56)

| Verificação | Resultado |
|---|---|
| Destroy | executado pelo usuário com `force_destroy=true` já aplicado; state atualizado às 13:55:58 (serial 55, **0 recursos**). Os 17 saíram: `head-bucket` dá 404 nos dois buckets e `get-role lab-s3-repl-role` dá `NoSuchEntity` |
| `scripts/inventory.sh` | **CLEAN** |
| IAM compartilhado | `lab-s3-replication` v1 (0 attachments) e `terraform-lab-iam-lab-roles` v2 continuam; o `terraform-lab-role` mantém `PowerUserAccess` + a allow-list; `lab-s3-read-role` e `lab-storage-ec2-ssm` intactas |
| Metrics | os nomes ainda aparecem no `list-metrics` (4), por causa dos datapoints históricos. Sem regra, não há novos datapoints nem cobrança |

O objeto de evidência `repl/falha-deny-dia3.txt` saiu junto com o bucket, como planejado.

## Próximos cenários

1. ~~`deny_replicate_on_dst=true`~~: feito; ver o incidente acima.
2. ~~Delete markers~~: feito; ver os testes 3 e 4.
3. ~~Encerramento~~: feito; ver acima.
4. **Não feito:** regra desligada (`replication_rule_enabled=false`). O que for escrito nesse intervalo nunca replica, nem depois de religar; para esses objetos o caminho é S3 Batch Replication. Fica para uma próxima vez: a stack sobe de novo com um `apply`.
