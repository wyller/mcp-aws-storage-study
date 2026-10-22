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
- **`OperationsFailedReplication` não apareceu.** Esta métrica só é publicada quando há falha; a ausência dela aqui é o esperado.
- **Atraso:** às 12:49 ainda não havia datapoints; eles apareceram até as 12:54. Na primeira leitura, `list-metrics` listou só uma das métricas e depois nenhuma. Durante esse atraso, o `list-metrics` oscila. Num incidente, não conclua nada de metrics com menos de ~5 min.
- **Antes do primeiro PUT**, as métricas já publicavam zero: a regra gera datapoints mesmo sem tráfego. É isso que cobra estando parado.

## Como cobra (o que está rodando agora)

- **Storage:** 2 × 37 B (objeto replicado) + 37 B (fora do filtro). Desprezível. Cada réplica é uma cópia cheia: replicar dobra o storage do que passa pelo filtro.
- **Requests:** o PUT da réplica no destino é cobrado como request normal. SRR não tem transferência entre regiões.
- **Metrics:** custom metrics do CloudWatch, cobradas por hora enquanto a regra existir, **mesmo sem tráfego**. É o que custa estando parado.

## Próximos cenários

1. `deny_replicate_on_dst=true`: um novo PUT em `repl/` deve ficar `FAILED`, com a regra ainda "Enabled". Ver `OperationsFailedReplication`.
2. Regra desligada (`replication_rule_enabled=false`): o que for escrito nesse intervalo nunca replica, nem depois de religar. Para esses objetos o caminho é S3 Batch Replication.
3. Delete markers: com `delete_marker_replication=false`, um DELETE sem version-id não chega ao destino; com `true`, chega. DELETE com version-id nunca replica.
4. Encerramento: `apply -var force_destroy=true`, depois `terraform destroy`, depois `scripts/inventory.sh`.
