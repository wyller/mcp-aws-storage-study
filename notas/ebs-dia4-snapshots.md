# EBS: Dia 4, snapshots, restore e latência do primeiro acesso (2026-10-27)

Código e runbook: `terraform/ebs-snapshots/README.md`. Evidências brutas em `notas/dados/ebs-dia4/`:

- `cloudtrail-timeline.tsv`: chamadas de EC2/EBS do dia;
- `ssm-commands.tsv`: freeze e thaw enviados pelo `take`;
- `cloudwatch-ebs-1min.json`: métricas por minuto dos três volumes.

- `destroy-plan-summary.txt`: os 10 recursos do destroy.

> **Os JSONs do fio e as saídas do `verify` não estão no repositório.** O `scripts/collect-fio.sh` não rodou antes do destroy, e os JSONs estavam no `/tmp` da EC2.
> Duas fontes, sempre marcadas:
> - **[usuário]**: números que o usuário viu no terminal da EC2 e mostrou ao ChatGPT por captura de tela; os valores vieram para o repo pela instrução do ChatGPT. Não há saída bruta guardada.
> - **[CloudWatch]**: médias por minuto do lado do EBS, que estão em `cloudwatch-ebs-1min.json`.

## Prova final do Dia 4: 9/10 (90%), aprovado

| # | Tema | Resultado |
|---|---|---|
| 1 | Crash consistency | correta |
| 2 | Snapshots incrementais | correta |
| 3 | Journal ext4 | **incorreta** |
| 4 | Automação de backups | correta |
| 5 | RPO e RTO | correta |
| 6 | Performance EBS / QD1 | correta |
| 7 | Recuperação entre AZs | correta |
| 8 | UUID duplicado | correta |
| 9 | Testes de restauração | correta |
| 10 | Recuperação PostgreSQL | correta |

**Ponto de revisão:** são três camadas diferentes, e cada uma só garante o que é dela.

| Camada | O que garante | O que **não** garante |
|---|---|---|
| **Estrutura do ext4** (inodes, bitmaps, diretórios) | Depois do replay do journal, o filesystem é válido: nada de inode órfão nem bloco em dois arquivos | Que o conteúdo dos arquivos esteja no ponto em que o app queria |
| **Journal do ext4** (`data=ordered`, o padrão) | Só **metadados** vão para o journal. Os blocos de dados são gravados antes do commit dos metadados que apontam para eles, então um arquivo nunca aponta para lixo. O replay reaplica as transações completas e descarta as incompletas | Os dados que ainda estavam no page cache (sem `fsync`) se perdem. O journal não sabe o que é uma transação do app |
| **WAL do PostgreSQL** | Com `fsync=on`, um `COMMIT` só retorna depois que o WAL foi gravado no disco. Na partida, o PostgreSQL refaz o WAL a partir do último checkpoint: o que foi commitado aparece e o que não foi fica invisível. É consistência **transacional** | Nada, se o filesystem embaixo não estiver íntegro, ou se o WAL e os dados estiverem em volumes com snapshots de momentos diferentes |

Na ordem da recuperação de um snapshot crash-consistent com PostgreSQL:

1. O kernel faz o replay do journal do ext4 e o filesystem fica íntegro.
2. O PostgreSQL faz o crash recovery pelo WAL e o banco fica transacionalmente consistente.

Um freeze não dispensa o passo 2. Ele só garante que o kernel gravou tudo o que tinha, e o PostgreSQL ainda vai rodar o recovery na partida. Para ser application-consistent, é preciso `pg_backup_start`/`pg_backup_stop`, ou um `CHECKPOINT` antes do freeze. Com `pg_wal` em outro volume, o snapshot tem de ser multi-volume (`create-snapshots`), para os dois volumes ficarem no mesmo ponto no tempo.

## Linha do tempo (horário de Brasília, UTC-3; CloudTrail)

| Hora | O quê |
|---|---|
| 14:31–14:32 | apply da base: volume de dados `vol-09149225ba52376eb`, EC2 `i-002fb752e4afc004a`, attach em `/dev/sdf` |
| 14:46:30 | `CreateSnapshot` s1 `snap-0dc5267044a197a10`, com freeze (`take s1`) |
| 15:16:54 | `CreateSnapshot` s2 `snap-03f145d41e65c93e2`, **também com freeze** (`take s2`, não pelo Terraform como no passo 4) |
| 15:39:44 | `CreateVolume` a partir do s1: `vol-0d1d94beabdb4aef4`, attach em `/dev/sdg` |
| 16:10:25 | `CreateVolume` a partir do s2 **negado**: o apply rodou como `readonly-user` (`Client.UnauthorizedOperation`) |
| 16:12:07 | `CreateVolume` a partir do s2, já com `aws-lab`: `vol-07b5b833283abc70e`, attach em `/dev/sdh` |
| 16:20:37–16:21:09 | destroy: 10 recursos |

O plano negado não deixou nada para trás: a AWS recusou o `CreateVolume`, então nada foi criado. O usuário gerou um plano novo (`r2retry.tfplan`) com a role certa.

## Freeze medido (SSM `list-commands`)

| Snapshot | freeze enviado | `CreateSnapshot` | thaw enviado | Janela máxima de freeze |
|---|---|---|---|---|
| s1 | 14:46:18,9 | 14:46:30 | 14:46:32,3 | ~13 s |
| s2 | 15:16:43,1 | 15:16:54 | 15:16:56,6 | ~13 s |

Essa janela é um limite superior: vai do pedido do freeze até o pedido do thaw. Quase tudo é ida e volta do SSM: ~11 s até o `CreateSnapshot`, que leva menos de 1 s. Do snapshot até o thaw são ~2 s.

Num app real, 13 s de escrita bloqueada é timeout. Para encurtar, o freeze, o snapshot e o thaw teriam de rodar na própria instância, como faz o AWS Backup/DLM com pre/post scripts. Aqui isso foi evitado de propósito: a role da EC2 não pode criar snapshot.

## Integridade dos restores

| Teste | Resultado |
|---|---|
| `verify s1 /mnt/lab-restored` | **OK: 1004 arquivos, sem extras** [usuário] |
| `verify s2 /mnt/lab-restored-s2` | **OK: 905 arquivos** [usuário] |
| `verify s1` no restore do s2 e `verify s2` no restore do s1 | **falharam, como esperado** [usuário] |
| `diff s1.sha256 s2.sha256` | não foi registrado. Pela construção do `mutate`, seriam 103 linhas: 100 apagados + `random-1.bin` (antigo e novo) + `random-5.bin` |

O detalhe de cada falha cruzada (quais arquivos) não foi guardado. Pelo `mutate`, o `verify s1` no restore do s2 acusaria o `random-1.bin` alterado, 100 arquivos ausentes e `new/random-5.bin` como extra.

O que muda entre os estados (`lab-ebs mutate`):

- 8 MiB sobrescritos no início de `big/random-1.bin`;
- 100 arquivos de 4 KiB apagados (`small/f-0001..0100`);
- 32 MiB novos (`new/random-5.bin`).

Resultado: 1004 arquivos no s1, 905 no s2.

O incremental confirma essa diferença: `blocks s1 s2` deu **92 blocos de 512 KiB = 46 MiB**. São os 40 MiB de dados mais metadados do ext4 e o journal. Os arquivos apagados não acrescentam blocos de dados, só mudanças de metadados. Esses 46 MiB são uma contagem de blocos, não a fatura (ver o README, "Changed blocks are not the bill").

## Desempenho

Cada `latency` roda fio randread de 4 KiB, QD1, 60 s, `--direct`. O `init` faz leitura sequencial de 1 MiB com QD32 no device inteiro.

**fio** [usuário]:

| Teste | Volume | IOPS | Throughput | p50 | p99 |
|---|---|---|---|---|---|
| `restored-cold` | restore s1 | 1.640 | 6,4 MiB/s | 0,59 ms | 0,94 ms |
| `restored-warm` | restore s1, depois do `init` | 1.667 | 6,5 MiB/s | 0,58 ms | 0,93 ms |
| `source` | dados (nunca restaurado) | 1.646 | 6,4 MiB/s | 0,59 ms | 0,91 ms |
| `init` | restore s1, 20 GiB | 126 (I/O de 1 MiB) | 126 MiB/s | 246,42 ms | 304,09 ms |

**CloudWatch**, por minuto e do lado do EBS (os 60 s de cada teste cruzam a virada do minuto, então o IOPS é a soma dos dois minutos dividida por 60):

| Teste (horário) | IOPS | Throughput | Latência **média** de leitura |
|---|---|---|---|
| `restored-cold` (15:55–15:56) | ~1.640 | ~6,4 MiB/s | 0,55 ms |
| `init` (15:58–16:00) | ~500 (I/O de 256 KiB) | ~125 MiB/s | 2,6 ms |
| `restored-warm` (16:01–16:02) | ~1.680 | ~6,5 MiB/s | 0,55 ms |
| `source` (16:03–16:04) | ~1.650 | ~6,4 MiB/s | 0,55 ms |

As duas fontes batem: o IOPS do fio e o do CloudWatch diferem menos de 1%.

- **No `init`, o IOPS difere por causa do tamanho de I/O que cada lado conta.** O fio conta 126 I/Os de 1 MiB, e o EBS conta ~500 de 256 KiB: cada 1 MiB chega ao EBS dividido em quatro.
- **A latência difere porque mede trechos diferentes.** O p50 de 246 ms do fio inclui a fila dentro da instância. Pela lei de Little, 32 I/Os em fila ÷ 126 IOPS ≈ 254 ms. Já os 2,6 ms do CloudWatch são só o tempo de serviço no EBS.

Os dois volumes restaurados tiveram **0 `VolumeWriteOps`** do attach ao detach [CloudWatch].

Leitura SRE:

- **Cold, warm e source empataram**, inclusive na cauda: o p99 foi de 0,94, 0,93 e 0,91 ms. A hipótese 3 (lazy loading) **não apareceu nesta medição**.
  - **Isso não prova que não há lazy loading.** Só mostra que ele não pesou neste cenário.
  - **Explicação mais provável:** o cold rodou ~15 min depois do `CreateVolume`, e o s1 tem só ~260 MiB de dados escritos. A inicialização padrão do EBS baixa os blocos em segundo plano, a uma taxa que varia ([docs](https://docs.aws.amazon.com/ebs/latest/userguide/initalize-volume.html)), e provavelmente já tinha terminado. Blocos nunca escritos na origem nem existem no snapshot.
  - **Não verificado:** ninguém olhou `describe-volume-status ... InitializationStatusDetails.Progress` antes do cold.
  - **Onde aparece:** volume grande, cold logo depois do attach, um dataset de vários GiB, ou um banco que lê páginas aleatórias logo depois de um restore em produção.
  - **Para refazer:** rodar o cold logo depois do attach, com o `Progress` abaixo de 100, e um dataset de vários GiB.
- **Por que QD1 não chega aos 3.000 IOPS do gp3.** Com QD1, há sempre um único I/O em voo, então IOPS = 1 ÷ latência = 1 ÷ 0,6 ms ≈ 1.650.
  - Os 3.000 IOPS são um **teto**, não uma garantia por I/O, e só aparecem com I/Os em paralelo: QD ≥ 2 já passaria de 3.000 e encostaria no limite.
  - A latência por I/O (~0,6 ms) é física da rede até o EBS e não cai provisionando mais IOPS.
  - Os ~0,05 ms entre a média do EBS (0,55 ms) e o tempo por I/O do fio (~0,6 ms) são o caminho dentro da instância.
- **O `init` bateu no teto de throughput do gp3:** ~125 MiB/s. Os 20 GiB levaram ~2,7 min.
  - **Ressalva do Dia 1:** o t3.micro tem um *baseline* de EBS bem menor (e cerca de 500 IOPS de baseline) e só aguenta isso em burst. Num `init` mais longo, o limite da instância apareceria antes do limite do volume (ver `ebs-dia1-parte2-limite-instancia.md`).
- **A média do CloudWatch esconde a cauda.** Um efeito de lazy loading apareceria primeiro no p99, por isso os percentis do fio importam. Aqui os p99 do fio também empataram, o que reforça a leitura das médias.

## Montagem do ext4: o que se observou e o que significa

- **s1 e s2 vieram de freeze** (`take` com `lab-ebs freeze 60`, confirmado no `ssm-commands.tsv`), então ambos estavam limpos: o freeze esvazia o journal e limpa a flag `needs_recovery`. Os dois montaram em device read-only (`blockdev --setro` + `mount -o ro`).
- **Não houve replay de journal.** O CloudWatch mostra 0 gravações nos dois restores, e nenhum replay foi observado na montagem. O dmesg não foi guardado.
- **Crash consistency não foi testada.** O passo 4 do runbook (s2 pelo Terraform, sem freeze, com o writer gravando) foi trocado por `take s2`. Num snapshot assim, o ext4 está com `needs_recovery`:
  - `mount -o ro` num device gravável **faz o replay e grava no volume restaurado**;
  - num device read-only, a montagem falha com `write access unavailable, cannot proceed`;
  - o `writer check` mostraria quanto do que estava no page cache se perdeu.

  Isso fica para outra rodada.
- **`ro` não quer dizer "não grava".** No ext4, `-o ro` ainda faz o replay do journal se for preciso. Só o `blockdev --setro` garante nada gravado. Já `-o ro,noload` pula o replay, mas mostra um filesystem sem os metadados que ainda estavam só no journal.
- **UUID e LABEL duplicados:** os três volumes (dados, restore s1, restore s2) tinham o mesmo UUID e o mesmo LABEL `lab-data`. Isso vem da própria natureza do snapshot, que copia blocos, incluindo o superbloco onde ficam o UUID e o LABEL. O valor do UUID não foi registrado.
  - O ext4 aceitou montar todos ao mesmo tempo, sem aviso. O XFS recusaria sem `-o nouuid`.
  - O risco real é o `/etc/fstab` com `UUID=`/`LABEL=` e os links `/dev/disk/by-uuid`/`by-label`: depois de um reboot, podem montar o volume errado em produção, por exemplo o restore no lugar do original.
  - Aqui tudo montou pelo serial NVMe (volume ID sem hífen). `tune2fs -U` resolveria o conflito, mas grava metadados no restore; não foi usado.

## Custo (estimado)

O lab ficou de pé ~1,8 h:

| Item | Custo |
|---|---|
| EC2 | ~US$ 0,019 |
| IPv4 | ~US$ 0,009 |
| gp3 (8 + 20 GiB, mais os restores por 0,7 h e 0,15 h) | ~US$ 0,007 |
| Snapshots (poucas horas, ~0,3 GB) | menos de US$ 0,001 |
| **Total** | **~US$ 0,04** |

Não houve FSR nem archive tier. O valor real aparece no Cost Explorer no dia seguinte.

## Limpeza (2026-10-27, conferida só com leitura)

- `terraform.tfstate` da stack: 0 recursos, 0 outputs.
- Snapshots, volumes, EIPs e FSR: nenhum. SG `lab-ebs-snap-*`: nenhum. Recycle Bin: nenhuma regra.
- EC2 `i-002fb752e4afc004a`: `terminated`.
- `scripts/inventory.sh`: **CLEAN**.
- Mantidos (`iam-compartilhado`): `lab-storage-ec2-ssm`, `lab-storage-ec2-profile`, a attachment `AmazonSSMManagedInstanceCore` e a `terraform-lab-role` (`MaxSessionDuration` 14400).

## Lições

1. **Rodar o `collect-fio.sh` antes do destroy.** O que fica no `/tmp` da EC2 morre com ela, e o CloudWatch só guarda a média.
2. **Conferir `aws sts get-caller-identity` antes de cada apply.** O primeiro apply do restore do s2 rodou como `readonly-user`. A AWS negou e nada foi criado, mas o plano salvo teve de ser refeito.
3. **Lazy loading não aparece em volume pequeno medido tarde.** Para medir o cold, ele tem de rodar logo depois do attach, com o `Progress` da inicialização abaixo de 100.
4. **O freeze via SSM custa ~13 s** de escrita bloqueada, quase tudo latência do Run Command.
5. **Montar pelo volume ID (serial NVMe), nunca por UUID/LABEL**, sempre que houver restore e original na mesma máquina.

## Não testado (para uma próxima rodada)

- Snapshot crash-consistent com o writer rodando, replay do journal e `writer check`.
- Apagar o s1 e restaurar o s2 depois (a cadeia incremental sobreviver ao delete).
- Um cold de verdade, com o `Progress` da inicialização abaixo de 100.
