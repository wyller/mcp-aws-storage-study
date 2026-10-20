# EBS gp3: Dia 1, benchmark com fio (2026-10-19)

Código: `terraform/ebs/LAB-DIA-1-gp3-3000IOPS-125mibToSecondtroiughput.tf`. Desde o Dia 2, a role e o instance profile do SSM ficam em `terraform/iam-compartilhado` (aplicar antes) e o volume/EC2 aceitam variáveis (`volume_size`, `volume_iops`, `volume_throughput`, `instance_type`).

## O que foi criado (us-east-1, us-east-1a)

| Recurso | ID / nome | Config |
|---|---|---|
| EC2 | `i-0e9ccc74bdbaf2b30` (`lab-sre-storage-ec2`) | t3.micro, Ubuntu 24.04, IP público, sem SSH (acesso por SSM) |
| EBS de dados | `vol-0725e416ff21e55ef` (`lab-sre-storage`) | gp3 20 GiB, 3000 IOPS, 125 MiB/s, criptografado, `/dev/sdf` (aparece como `/dev/nvme1n1`) |
| EBS raiz | `vol-0a6809bb08bf616d7` | gp3 12 GiB, `DeleteOnTermination=true` |
| IAM role | `lab-storage-ec2-ssm` | trust `ec2.amazonaws.com` + `AmazonSSMManagedInstanceCore` |
| Instance profile | `lab-storage-ec2-profile` | |
| Security group | `sg-05f0634ca82e7f236` (`lab-storage-*`) | sem entrada, saída liberada (o SSM só precisa de saída 443) |

## Como cobra

| Item | Preço us-east-1 | Cobra parado? |
|---|---|---|
| t3.micro | ~US$ 0,0104/h | não quando `stopped` (mas os discos e o IP continuam) |
| IPv4 público | US$ 0,005/h | sim, enquanto estiver alocado |
| gp3 | US$ 0,08/GiB-mês; 3000 IOPS e 125 MiB/s inclusos | **sim**: volume `available` (desanexado) cobra igual |
| gp3 acima do baseline | US$ 0,005/IOPS-mês e US$ 0,04/MiB/s-mês | sim |

Lab inteiro: ~US$ 0,02/h. O que pega desprevenido é o volume de dados com `DeleteOnTermination=false`. Ele sobrevive ao terminate da EC2 e continua cobrando ~US$ 1,60/mês.

## Resultados do fio e do iostat

> Resultados observados em **testes distintos**, um rodado depois do outro. Não são uma medição controlada lado a lado. O `bs` não ficou registrado. Como IOPS ≈ MiB/s, o tamanho de bloco foi de **~1 MiB** (inferido). O iostat mostra `w_await`, então eram **escritas**.

| fio | Throughput | IOPS | lat média | lat p99 |
|---|---|---|---|---|
| QD 1 | 129 MiB/s | 129 | 7,7 ms | ~8,1 ms |
| QD 8 | 127 MiB/s | 127 | 62,8 ms | ~81 ms |

| iostat (`nvme1n1`) | w_await | aqu-sz | %util |
|---|---|---|---|
| QD 1 | ~5,1 ms | ~2,6 | ~98% |
| QD 8 | ~59 ms | ~29,7 | ~100% |

## Queue depth 1 vs 8: o que os números mostram

- **O throughput não mudou (~128 MiB/s), só a latência subiu ~8x.** Com QD1 o teto já tinha sido atingido. O QD8 só formou fila.
- Pela lei de Little (**fila = vazão × latência**): 8 / 127 IOPS ≈ 63 ms, igual à latência média medida (62,8 ms). Quando o teto de vazão é fixo, mais I/O em voo vira espera.
- O `aqu-sz` (~29,7) ficou maior que o iodepth (8). Hipótese: o kernel quebra cada I/O de 1 MiB em pedaços menores (`max_sectors_kb`), e o iostat conta os pedaços. Isso não foi verificado. Para conferir, rode `cat /sys/block/nvme1n1/queue/max_sectors_kb`.
- `%util` ~100% em NVMe/EBS **não prova saturação**, porque o dispositivo atende em paralelo. O que prova é a vazão parada num teto e o `await` subindo.
- **Lição de troubleshooting**: aumentar o QD só ajuda quando o gargalo é latência (blocos pequenos e QD baixo). Quando o gargalo é vazão, aumentar o QD só piora a latência.

### Gargalo: ainda não isolado

~128 MiB/s bate com dois limites ao mesmo tempo:

| Candidato | Limite | Fonte |
|---|---|---|
| Volume gp3 | 125 MiB/s provisionados (~131 MB/s) | config do volume |
| Instância t3.micro (EBS) | baseline **10,9 MB/s**, burst até **260,6 MB/s** por ~30 min com crédito | `aws ec2 describe-instance-types --instance-types t3.micro` e [docs](https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html) |

O mais provável é o teto do **volume**, porque a instância ainda estava em burst e o teto do burst (260 MB/s) fica acima do que foi medido. Isso **não foi confirmado**. Como isolar no próximo lab:

1. Subir o throughput do gp3 (ex.: 250 MiB/s com `modify-volume`) e repetir. Se a vazão subir, o teto era o volume.
2. Ver no CloudWatch o `EBSByteBalance%` da instância e o `VolumeThroughputPercentage`/`VolumeWriteBytes` do volume durante o teste.
3. Num teste longo (>30 min) na t3.micro, a vazão deve despencar para ~11 MB/s quando o crédito de burst acabar.
4. Salvar a saída: `fio ... --output-format=json --output=qd1.json`.

## Problemas do dia e soluções

- **403 no Terraform**: estava rodando como `readonly-user`. Criei a `terraform-lab-role` (PowerUser + MFA) e o `aws-lab`.
- **403 em `iam:CreateRole`**: a PowerUser não inclui IAM. Criei a policy `terraform-lab-iam-lab-roles`, que só vale para `lab-*`.

## Limpeza

`terraform destroy` (7 recursos) remove tudo da tabela acima. O volume raiz cai junto com a instância.

Feito em 2026-10-19 ~21:13 UTC e conferido na AWS: instância `terminated`, sem volumes, snapshots, ENIs, EIPs ou o SG do lab. O inventário de todas as regiões deu LIMPO.

A `lab-s3-read-role` (role + instance profile, de 2026-05-30) **fica** para o Dia 2 (S3). Ela está protegida no `nuke-config.yaml` e no statement `NegarLabS3ReadRole` de `policies/claude-cleanup-delete-only.json`. Esse Deny só vale depois de colado no console.
