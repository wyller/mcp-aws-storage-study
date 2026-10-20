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

## Dia 3: EBS snapshots, restore e o primeiro acesso lento

- **Hipótese:** um volume restaurado de snapshot fica lento na primeira leitura de cada bloco, porque busca os dados do S3 sob demanda. Ler o volume inteiro com fio "aquece" o disco.
- **Lab:** snapshot do volume, restore, leitura completa com fio (medindo o p99 antes e depois), além do teto de **IOPS** da t3.micro (11.800), que ficou pendente: randwrite 4k, QD 64, volume ≥ 24 GiB.
- **Como cobra:** snapshot por GB-mês incremental, archive tier (mais barato, com restore pago e mínimo de 90 dias). **Fast Snapshot Restore cobra ~US$ 0,75/h por AZ: não habilitar**, só estudar.
- **Custo do lab:** < US$ 0,30 (o teste de IOPS tem ~US$ 0,09/h extra de IOPS provisionadas, por até 1 h).
- **Limpeza:** snapshots ficam fora do state se forem criados pelo console. O inventário pega.

## Dia 4: EFS contra EBS

- **Hipótese:** o EFS no modo Elastic escala o throughput sem provisionar, mas a latência por operação é maior que a do EBS. Com arquivos pequenos e QD baixo, ele perde de muito.
- **Lab:** EFS com mount target numa AZ, montado via NFS na EC2. Mesmo fio da parte 2 (seq 1M) e um teste de arquivos pequenos. Comparar a latência com o gp3.
- **Como cobra:** GB-mês por classe (Standard e IA), mais leitura e escrita por GB no modo Elastic. O mount target não cobra por hora.
- **Custo do lab:** < US$ 0,10.
- **Limpeza:** o mount target precisa sair antes do file system. O Terraform cuida da ordem.

## Dia 5: AWS Backup e restore testado

- **Hipótese:** backup que nunca foi restaurado não é backup. O tempo de restore (RTO) se mede, não se supõe.
- **Lab:** plano do AWS Backup para um volume EBS por tag, um job sob demanda, restore e checagem do conteúdo (sha256 antes e depois).
- **Como cobra:** armazenamento de backup por GB-mês, restore por GB em alguns recursos. O vault não cobra.
- **Custo do lab:** < US$ 0,10.
- **Limpeza:** os recovery points precisam ser apagados antes do vault. Vault Lock **não** pode ser habilitado num lab.

## Depois (com custo a avaliar antes)

- **FSx for Lustre:** o mínimo é de 1,2 TiB, ~US$ 0,20/h por algumas horas. Só com orçamento definido.
- **DataSync e Storage Gateway:** o gateway tem VM ou EC2 de porte maior e cobra por GB transferido. Planejar à parte.
