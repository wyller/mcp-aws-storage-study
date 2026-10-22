# Plano dos próximos dias (até 4 h cada)

## Formato fixo

| Bloco | Tempo | O quê |
|---|---|---|
| Revisão | 30 min | ler a nota anterior, o modelo de cobrança do serviço e a hipótese do dia |
| Lab | 2 h | `terraform plan` → apply → testes, com hipótese → comando → resultado |
| Exercícios | 45 min | 10 questões de troubleshooting e custo, sobre o que foi medido |
| Limpeza e nota | 30 min | coletar os dados, `plan -destroy`, `destroy`, `scripts/inventario.sh`, nota e commit |
| Folga | 15 min | imprevistos |

**Regra de corte:** com **3 h 15 min** de sessão, para tudo e começa a limpeza, termine ou não o lab. O que faltar vira o "Próximo" da nota. O stack `terraform/iam-compartilhado` nunca entra no destroy.

## Dia 2: S3 por dentro e o 403 clássico

- **Hipótese:** um `AccessDenied` de S3 vindo de uma EC2 pode ter quatro causas (a IAM da role, a bucket policy, a chave KMS ou o endpoint da VPC), e cada uma deixa uma assinatura diferente.
- **Lab:** um bucket e uma EC2 com a `lab-s3-read-role`, já existente e protegida. Provocar e diagnosticar cada causa de 403. Versionamento com delete marker, lifecycle para IA e Glacier, gateway endpoint de S3 (grátis) contra NAT (pago).
- **Como cobra:** GB-mês por classe, requisição (PUT custa ~10 vezes mais que GET), transferência para a internet, duração mínima e taxa de recuperação nas classes IA e Glacier.
- **Custo do lab:** < US$ 0,05 (EC2 por ~2 h e alguns MB no S3).
- **Limpeza:** versões e delete markers seguram o bucket (o `rb` falha se não esvaziar todas as versões).
- **Feito em 2026-10-21** ([nota](s3-dia2-403-versionamento.md)): sem EC2, KMS nem endpoint. O 403 ficou entre o IAM e a bucket policy (deny explícito, deny implícito, 403 no lugar do 404 sem `ListBucket`), além do versionamento com delete marker, da recuperação de versão e da auditoria do lifecycle. As causas KMS e endpoint, a EC2 com a `lab-s3-read-role` e o lifecycle para IA/Glacier ficaram para o bloco "S3 + KMS", em "Depois".

## Dia 3: S3 Replication e Performance

Redefinido em 2026-10-22: EBS snapshots passou para o Dia 4, e EFS e Backup desceram um dia.

- **Hipótese:** a replicação é assíncrona e só cobre o que a regra enxerga. Objetos fora do filtro, gravados antes da regra (ou com ela desligada), deletes por `version-id` e réplicas não replicam. Uma falha de permissão no destino não aparece na regra: só no `x-amz-replication-status` (`FAILED`) e nas replication metrics.
- **Lab:** SRR em us-east-1, com dois buckets versionados (`lab-s3-repl-src-*` e `lab-s3-repl-dst-*`), a role `lab-s3-repl-role` e a managed policy `lab-s3-replication` (criada no console). Status `PENDING` → `COMPLETED`/`REPLICA`, o que não replica, falha provocada por deny na bucket policy do destino, e performance com teto: PUTs pequenos em série contra paralelos, upload de 100 MiB com e sem multipart, e latência de replicação do objeto pequeno contra o de 100 MiB. Stack em `terraform/s3-replication`.
- **Pré-requisito:** a `terraform-lab-role` não cria policy e só passava role para a EC2. A allow-list ganha a `lab-s3-replication` e um PassRole de `lab-s3-repl-*` para `s3.amazonaws.com` (ver `SETUP.md`).
- **Como cobra:** armazenamento nos **dois** buckets (a réplica é cobrada inteira), PUT de replicação no destino, replication metrics como custom metric do CloudWatch (proporcional por hora) e nada de transferência no SRR. CRR soma ~US$ 0,02/GB entre regiões. RTC (US$ 0,015/GB) e Batch Replication (Batch Operations por job e por objeto) só no estudo.
- **Custo do lab:** < US$ 0,05.
- **CRR:** extensão opcional, só depois de avaliar o custo.
- **Limpeza:** esvaziar os dois buckets (as réplicas também têm versões), `plan -destroy` e `destroy`. A managed policy fica entre os dias, protegida no `nuke-config.yaml`.

## Dia 4: EBS snapshots, restore e o primeiro acesso lento

- **Hipótese:** um volume restaurado de snapshot fica lento na primeira leitura de cada bloco, porque busca os dados do S3 sob demanda. Ler o volume inteiro com fio "aquece" o disco.
- **Lab:** snapshot do volume, restore, leitura completa com fio (medindo o p99 antes e depois), além do teto de **IOPS** da t3.micro (11.800), que ficou pendente: randwrite 4k, QD 64, volume ≥ 24 GiB.
- **Como cobra:** snapshot por GB-mês incremental, archive tier (mais barato, com restore pago e mínimo de 90 dias). **Fast Snapshot Restore cobra ~US$ 0,75/h por AZ: não habilitar**, só estudar.
- **Custo do lab:** < US$ 0,30 (o teste de IOPS tem ~US$ 0,09/h extra de IOPS provisionadas, por até 1 h).
- **Limpeza:** snapshots ficam fora do state se forem criados pelo console. O inventário pega.
- **Código pronto** (commit `665ce3a`): `create_snapshot` e `restore_from_snapshot` em `terraform/ebs`, desligados por padrão.

## Dia 5: EFS contra EBS

- **Hipótese:** o EFS no modo Elastic escala o throughput sem provisionar, mas a latência por operação é maior que a do EBS. Com arquivos pequenos e QD baixo, ele perde de muito.
- **Lab:** EFS com mount target numa AZ, montado via NFS na EC2. Mesmo fio da parte 2 (seq 1M) e um teste de arquivos pequenos. Comparar a latência com o gp3.
- **Como cobra:** GB-mês por classe (Standard e IA), mais leitura e escrita por GB no modo Elastic. O mount target não cobra por hora.
- **Custo do lab:** < US$ 0,10.
- **Limpeza:** o mount target precisa sair antes do file system. O Terraform cuida da ordem.

## Dia 6: AWS Backup e restore testado

- **Hipótese:** backup que nunca foi restaurado não é backup. O tempo de restore (RTO) se mede, não se supõe.
- **Lab:** plano do AWS Backup para um volume EBS por tag, um job sob demanda, restore e checagem do conteúdo (sha256 antes e depois).
- **Como cobra:** armazenamento de backup por GB-mês, restore por GB em alguns recursos. O vault não cobra.
- **Custo do lab:** < US$ 0,10.
- **Limpeza:** os recovery points precisam ser apagados antes do vault. Vault Lock **não** pode ser habilitado num lab.

## Depois (com custo a avaliar antes)

Decisão de 2026-10-21: KMS é estudado **separadamente** e antes. O S3 volta depois, já com KMS.

- **KMS por conta própria:** chave gerenciada pelo cliente, key policy contra IAM (a key policy precisa liberar a conta), grants, rotação e `ScheduleKeyDeletion` (7 a 30 dias). **Como cobra:** US$ 1/mês por chave, proporcional por hora, mesmo sem uso; requisições de API além do free tier; a rotação soma US$ 1/mês na 1ª e na 2ª; chave em `PendingDeletion` não cobra ([pricing](https://aws.amazon.com/kms/pricing/)). Um lab de algumas horas sai por centavos, desde que a chave seja agendada para deleção no fim.
- **S3 + KMS (volta ao Dia 2):** SSE-KMS e o 403 por falta de `kms:Decrypt`/`GenerateDataKey` (a assinatura do erro é diferente da bucket policy), Bucket Key para reduzir as chamadas ao KMS, EC2 com a `lab-s3-read-role`, gateway endpoint de S3 (grátis) com endpoint policy contra NAT (pago), e lifecycle para IA e Glacier (duração mínima e mínimo de 128 KiB).

- **FSx for Lustre:** o mínimo é de 1,2 TiB, ~US$ 0,20/h por algumas horas. Só com orçamento definido.
- **DataSync e Storage Gateway:** o gateway tem VM ou EC2 de porte maior e cobra por GB transferido. Planejar à parte.
