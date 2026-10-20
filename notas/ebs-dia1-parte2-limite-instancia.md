# EBS gp3: Dia 1, parte 2. Quem limita, o volume ou a EC2? (2026-10-20)

Continuação de [ebs-dia1-gp3-fio.md](ebs-dia1-gp3-fio.md). Na parte 1, ~128 MiB/s batia com dois limites ao mesmo tempo e o gargalo ficou sem isolar. Aqui ficou isolado.

Código: `terraform/ebs/LAB-DIA-1-gp3-3000IOPS-125mibToSecondtroiughput.tf` (volume e EC2, com variáveis) e `terraform/iam-compartilhado` (role e profile do SSM, ficam entre os dias). Dados brutos do fio: [`dados/ebs-dia1/`](dados/ebs-dia1/), conferidos por `SHA256SUMS` e coletados com `scripts/coletar-fio.sh`.

## Setup

| Recurso | ID | Config |
|---|---|---|
| EC2 | `i-0fed42f1bd1beefb4` | t3.micro, us-east-1a, acesso por SSM |
| EBS de dados | `vol-0852e569cc7f00f4a` | gp3 20 GiB, 3000 IOPS, 125 → **400** MiB/s; `/dev/sdf` = `nvme1n1`, ext4 em `/mnt/lab-sre-storage` |
| EBS raiz | `vol-036e39395a1fe3fa0` | gp3 12 GiB, 3000 IOPS, 125 MiB/s |

fio em todas as fases: escrita sequencial, `bs=1M`, `iodepth=8`, `direct=1`, `libaio`, arquivo de 4 GiB em `/mnt/lab-sre-storage`, com o mount conferido antes (`findmnt -n -o SOURCE -T` igual a `/dev/nvme1n1`).

## Provisionado no gp3 contra limites da t3.micro

| | Volume gp3 (fase A) | Volume gp3 (fases B e C/D) | t3.micro baseline | t3.micro burst |
|---|---|---|---|---|
| Throughput | 125 MiB/s ≈ 131 MB/s | 400 MiB/s ≈ 419 MB/s | **10,875 MB/s** ≈ 10,37 MiB/s | **260,625 MB/s** ≈ 248,5 MiB/s |
| IOPS | 3000 | 3000 | 500 | 11.800 |

Fontes: `aws ec2 describe-instance-types --instance-types t3.micro` e a configuração do volume. **O desempenho efetivo é o menor dos dois limites** ([docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-optimization-performance.html)):

- **Fase A:** 131 MB/s do volume < 260,6 MB/s do burst, então quem manda é **o volume**, enquanto a instância tiver crédito.
- **Fases B e C/D:** 419 MB/s do volume > 260,6 MB/s do burst, então quem manda é **a instância**: primeiro o burst, depois o baseline.
- O throughput do volume também fica acima do **baseline** da instância (131 > 10,9 MB/s). Por isso, mesmo na fase A, um teste longo o bastante acabaria limitado pela instância.

## O que foi medido

### fio

| Fase | Volume | Duração | Throughput | Lat média | Lat p99 |
|---|---|---|---|---|---|
| A | 125 MiB/s | 120 s | **126,23 MiB/s** | 58,05 ms | 66,85 ms |
| B | 400 MiB/s | 120 s | **250,60 MiB/s** | 29,16 ms | 32,37 ms |
| C/D | 400 MiB/s | 2400 s | **178,79 MiB/s** de média; ~248 MiB/s no começo e **~10,3 MiB/s** no fim | 40,91 ms | **700,45 ms** |

Arquivos: `lab-fio-fase-a.json`, `lab-fio-fase-b.json`, `lab-fio-fase-cd.json`. O `lab-fio-controle.json` (126,23 MiB/s) é o teste **inválido**: o `disk_util` do próprio fio registra `nvme0n1`, o volume raiz.

Curva da fase C/D, em média por minuto (`lab-fase-cd_bw.1.log`, uma amostra a cada 10 s):

| Minuto | 0 | 1 a 27 | 28 | 29 a 39 | 40 |
|---|---|---|---|---|---|
| MiB/s | 253,5 | **248,5 a 248,6** | 115,9 (transição) | **10,4** | 10,3 |

### CloudWatch

| Métrica | Observado |
|---|---|
| `InstanceEBSThroughputExceededCheck` (AWS/EC2) | **0** na fase A, **1** nas fases B e C/D |
| `VolumeWriteBytes` do volume de dados, por minuto, na fase C/D | ~260,6 MB/s de 09:37 a 10:05 (Brasília); 18,7 MB/s às 10:06; **10,8 a 10,9 MB/s** de 10:07 até o fim |
| `EBSByteBalance%` (AWS/EC2) na fase C/D | 93% → 0%, caindo ~3,3 a 3,5 pontos por minuto, e chegando a **0 às 10:06** |
| `EBSByteBalance%` durante o teste que gravou no volume raiz por engano | 100% → 96% |
| `VolumeThroughputExceededCheck` (AWS/EBS) | aparece no `list-metrics`, mas **não publicou nenhum datapoint** durante os testes |
| `modify-volume` 125 → 400 MiB/s | `optimizing` de 12:19:03 a 12:24:08 UTC, com o `Progress` parado em 4% até pular para 100% |

### Conclusão (só com o que foi medido)

Com o volume em 400 MiB/s e nada mudado nele durante o teste, a vazão ficou em ~248 MiB/s e depois caiu para ~10,3 MiB/s. Esses dois patamares batem com o burst e o baseline da t3.micro. A queda coincidiu com o `EBSByteBalance%` chegando a 0, e o `InstanceEBSThroughputExceededCheck` ficou em 1 o tempo todo. **O gargalo das fases B e C/D era a instância.** Na fase A, com o check da instância em 0, era o volume.

Em regime, o throughput é **248,6 MiB/s = 260,6 MB/s**, exatamente o burst nominal. No fim, ficou em **10,4 MiB/s ≈ 10,9 MB/s**, exatamente o baseline. A média da fase B (250,60 MiB/s) e o minuto 0 da C/D (253,5) ficam acima do limite **só nos primeiros segundos** de cada teste. A causa desse começo acima do limite não foi investigada.

## Modelo de créditos: o que é hipótese

O modelo vem do [AWS Compute Blog](https://aws.amazon.com/blogs/compute/simulating-amazon-ec2-ebs-burst-credits-before-downsizing-an-instance/), não de medição direta:

- **Tamanho do saldo:** `(burst − baseline) × 1800 s = (260,625 − 10,875) × 1800 ≈ 449,5 GB`.
- **Consumo:** só a diferença entre o uso e o baseline. **Recarga:** `baseline − uso` por segundo, com o saldo limitado ao máximo.

| Afirmação | Situação |
|---|---|
| Com 93% de saldo e ~250 MB/s de consumo, o burst duraria ~28 min | **Consistente:** a queda veio a ~28,3 min, tanto pelo CloudWatch quanto pela média do fio (`248,5·t + 10,4·(2400 − t) = 178,79 × 2400`, o que dá t ≈ 1697 s) |
| Consumo de ~3,3% do saldo por minuto (250 MB/s × 60 ÷ 449,5 GB) | **Consistente** com os 3,3 a 3,5 pontos por minuto medidos |
| Na parte 1 (~131 MB/s), o burst duraria ~62 min, então o teto lá era o volume | **Inferido.** Não testei até esgotar |
| Encher o saldo do zero leva ~11,5 h (449,5 GB ÷ 10,875 MB/s) | **Hipótese**, não medida |
| O saldo é da instância, e todos os volumes anexados gastam dele | **Forte:** o teste no volume raiz baixou o `EBSByteBalance%` da instância |
| O p99 de 700 ms vem dos ~1,7% de I/Os feitos depois que o crédito acabou | **Forte:** a fase B, com a mesma config e sem período no baseline, teve p99 de 32 ms. A lei de Little dá 8 ÷ 10,4 IOPS ≈ 770 ms no baseline. Para confirmar I/O a I/O, falta um `write_lat_log` |
| Por que o `VolumeThroughputExceededCheck` não publicou | **Desconhecido** |

## Lições

- **O p99 mostra o throttling e a média não.** Na C/D, média de 41 ms e p99 de 700 ms. Na B, sem throttling, o p99 foi de 32 ms. Alarme de latência tem que ser em percentil.
- **Para separar volume de instância:** compare o check da instância (`InstanceEBS…ExceededCheck`) com o do volume, e o throughput medido com os dois limites. Neste lab, só a métrica da instância funcionou. As métricas EBS da instância chegaram a cada 1 min, mesmo sem detailed monitoring.
- **No console do CloudWatch, use Minimum e período de 1 min.** A média de 5 min mostrava o saldo em 91% quando ele já estava em 86%.
- **Lei de Little com QD 8:** 8/126 ≈ 63 ms (fase A, medido 58), 8/250 ≈ 32 ms (fase B, medido 29), 8/10,4 ≈ 770 ms (baseline). O `clat` medido fica um pouco abaixo porque não conta o tempo de submissão. Com o teto fixo, mais I/O em voo vira fila.
- **`modify-volume`:** até 4 por volume numa janela móvel de 24 h, cada uma depois da anterior chegar a `completed` ([docs](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-modify-volume.html)). O `Progress` não é linear: o que importa é o estado.
- **`EbsOptimized=False` na t3 não significa nada.** A t3 é otimizada para EBS por padrão (`EbsOptimizedSupport: default`) ([docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-optimized.html)).

## Problemas e soluções

- **O fio gravou no volume errado.** `/mnt/lab-sre-storage` era um diretório no `/`. O resultado pareceu certo (126 MiB/s) porque o volume raiz tem o mesmo perfil gp3 3000/125. O CloudWatch denunciou o erro: o volume de dados ficou com ~0 de escrita, e o raiz recebeu 15,9 GB.
  ```bash
  lsblk -o NAME,SIZE,SERIAL,MOUNTPOINT          # o SERIAL é o volume ID sem o hífen
  sudo mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 /dev/nvme1n1
  sudo mount /dev/nvme1n1 /mnt/lab-sre-storage
  findmnt -n -o SOURCE -T /mnt/lab-sre-storage   # tem que dar /dev/nvme1n1
  ```
- **Um plan que só mudava o volume substituía a EC2.** O `data "aws_subnet"` lia a AZ de `aws_ebs_volume.lab`. Com o volume mudando, o data source foi adiado para o apply, o `subnet_id` ficou `known after apply`, e isso forçou o replace. A correção foi ler a AZ de `data.aws_availability_zones`. Sempre leia o plan antes do `yes`.
- **403 ao rodar o apply com `!` dentro do Claude Code.** Esse shell usa o `readonly-user`. O apply roda no terminal do usuário, depois do `aws-lab`.

## Custo

| Momento | US$/h |
|---|---|
| Fase A (t3.micro + IPv4 + gp3 de 20 + 12 GiB) | ~0,019 |
| Com o volume em 400 MiB/s (+275 MiB/s × US$ 0,04/mês) | ~0,034 |

Fiz a fase B econômica, só com throughput. A versão com 32 GiB e 16.000 IOPS custaria ~US$ 0,125/h, e as IOPS a mais não mudavam nada num teste de throughput.

## Limpeza

Antes do destroy, os resultados foram copiados da EC2 com `scripts/coletar-fio.sh` (SSM Run Command, conferido por sha256). Depois, `terraform destroy -var volume_size=20 -var volume_iops=3000 -var volume_throughput=400`, com 4 recursos (volume, EC2, SG e attachment). O volume raiz caiu junto com a EC2.

Conferido na AWS em 2026-10-20, ~14:05 UTC:

- **Instância** `i-0fed42f1bd1beefb4`: `terminated` (14:01:08 UTC). Nenhuma outra instância fora de `terminated`.
- **Rede e disco:** sem volumes (nem `available`), snapshots, EIPs, ENIs ou SG `lab-storage-*` em us-east-1.
- **State do `terraform/ebs`:** 0 recursos.
- **`scripts/inventario.sh`** (todas as regiões): **LIMPO**.
- **IAM preservada:** `lab-storage-ec2-ssm` com o profile `lab-storage-ec2-profile` (state do `iam-compartilhado` com 3 recursos), `lab-s3-read-role`, `terraform-lab-role` e `claude-cleanup-role`.

## Próximo

- Teto de **IOPS** da instância (11.800): randwrite 4k, QD 64, com o volume em ≥ 24 GiB e > 11.800 IOPS (`IOPS ≤ 500 × GiB`).
- Repetir na `m7i.large` (`-var instance_type=m7i.large`). O baseline dela (81,25 MB/s) fica abaixo até dos 125 MiB/s padrão do gp3 (131 MB/s). Um teste longo também esgotaria o crédito, só que partindo de um teto de 1250 MB/s.
