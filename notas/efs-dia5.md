# EFS: Dia 5, Regional compartilhado entre duas AZs (2026-10-29)

Código e runbook: `terraform/efs/README.md`. Evidências brutas em `notas/dados/efs-dia5/`:

- `lab-fio-efs-*.json` (12) + `SHA256SUMS`: fio no EFS e no gp3 de controle, conferidos contra o sha256 calculado na EC2 (`collect-fio.sh`);
- `vis-v-1029-120155/`: experimento de visibilidade (JSON bruto do escritor e do leitor, stderr e `analysis.json`);
- `ssm-commands.tsv` e `ssm-outputs.txt`: os 39 comandos SSM do dia e a saída de cada um (lidos depois, com `get-command-invocation`);
- `cloudtrail-timeline.tsv`: criação, mudanças do SG e destroy;
- `cloudwatch-summary.txt`: bytes de I/O do EFS e CPU das EC2 na janela do lab;
- `EVIDENCE.sha256`: sha256 dos arquivos acima que não vieram da EC2.

Fonte de cada número: **[SSM]** saída do comando na EC2, **[fio]** JSON do fio, **[vis]** experimento, **[CloudTrail]**, **[CloudWatch]**.

## Resumo

| Hipótese | Resultado |
|---|---|
| 1. Cada cliente usa o mount target da própria AZ, e o outro vê o que foi gravado | **confirmada, com uma correção.** O DNS deu o IP da própria AZ nos dois clientes. Dados de um arquivo conhecido aparecem em ~10 ms (p50). Um **nome novo** procurado com `stat`/`open` levou até **57 s**: cache negativo do cliente NFS, não latência do EFS |
| 2. Sem lock, dois clientes perdem updates; com `flock`, não | **confirmada:** 302/600 sem lock (298 perdidos), 600/600 com lock |
| 3. Rede, policy e POSIX falham de jeitos diferentes | **confirmada:** policy = `access denied by server` em 0 s; rede = sem resposta, timeout em 45 s; POSIX = mount funciona, `Permission denied`/`Operation not permitted` na operação |
| 4. A latência por operação do EFS é bem maior que a do gp3 | **confirmada:** 4k QD1 5× (leitura) e 11× (escrita) mais lenta; arquivos pequenos com fsync 3,8× mais lentos; `rm` de 300 arquivos 267× mais lento. Paralelismo: 4 jobs deram 3,9× a vazão de 1 job no EFS |

## Linha do tempo (horário de Brasília, UTC-3)

| Hora | O quê | Fonte |
|---|---|---|
| 08:13:32 | `CreateFileSystem` `fs-03bf37dc9af454f83` (chave `aws/elasticfilesystem`) | CloudTrail |
| 08:13:38–39 | SG com 2049, 2 access points, file system policy, backup policy, 2 mount targets (`fsmt-06479475c9930ef36` 1a, `fsmt-069b2d9c82c1af0f5` 1b) | CloudTrail |
| 08:13:41–42 | `RunInstances`: a `i-0f3f1fa2f79d90646` (1a), b `i-00484ed8e1c1702e6` (1b) | CloudTrail |
| 08:29–08:31 | status, mount `app` e verify nos dois | SSM |
| 08:32–08:34 | `share s1` (primeira versão): 30 s e 60 s | SSM |
| 08:43 | `share s1` repetido: **falso positivo** (ver "Falhas e correções") | SSM |
| 09:02–09:05 | experimento de visibilidade `v-1029-120155` | SSM, vis |
| 09:09–09:10 | contadores c1 (nolock) e c2 (lock) | SSM |
| 09:29–09:31 | mounts `other` e `root`, `perms` | SSM |
| 09:33 | `try notls`, `try noiam` | SSM |
| 09:44:54 | `RevokeSecurityGroupIngress` (2049 removida) | CloudTrail |
| 09:45 | `net` sem resposta, `try blocked` com timeout | SSM |
| 09:49:58 | `AuthorizeSecurityGroupIngress` (rollback) | CloudTrail |
| 09:50 | `net` aberto nos dois, mount `app`, `probe` 38 e 50 ms | SSM |
| 09:51–10:01 | `perf efs-a`, `perf local-a local`, coleta do fio, `clean`, umount | SSM |
| 10:06:53–10:07:25 | destroy: mount targets → EC2 → SG do MT (23 s depois) → access points e SG dos clientes → file system | CloudTrail |

Tempo de vida: EC2 1 h 53 min, file system 1 h 54 min.

## Arquitetura

- **EFS:** Regional, General Purpose, Elastic Throughput, criptografado. Backup automático `DISABLED`, sem lifecycle.
- **Rede:** dois mount targets, em 1a e 1b. O SG deles aceita só TCP 2049 vindo do SG dos clientes e não tem egress.
- **Clientes:** duas `t3.micro` com AL2023 (`amazon-efs-utils` 3.3.4, `fio` 3.32), acessadas só por SSM com IPv4 público, sem NAT e sem endpoints.
- **Access points:**
  - `app` (`fsap-0643da71954c6efa9`): `/lab` como 1001:1001, diretório criado com 0750;
  - `other` (`fsap-064b7d123c16752c7`): `/` como 1002:1002.
- **File system policy:** só a `lab-storage-ec2-ssm` monta e escreve, só via mount target; TLS obrigatório; sem `ClientRootAccess`. A role compartilhada não mudou.

O mount helper monta com TLS por um túnel local. A saída do `verify` [SSM] mostra o processo:

```
/sbin/efs-proxy /var/run/efs/stunnel-config.fs-03bf37dc9af454f83.mnt.efs-app.20478 --tls --no-direct-s3-read
rw,relatime,vers=4.1,rsize=1048576,wsize=1048576,namlen=255,hard,noresvport,proto=tcp,port=20478,timeo=600,retrans=2,...,addr=127.0.0.1
```

O NFS fala com `127.0.0.1:<porta>`, e o `efs-proxy` (não mais o `stunnel`, nesta versão) leva TLS até o mount target na 2049. Sem `acdirmin`, `actimeo` nem `lookupcache` nas opções, valem os padrões do kernel.

## Visibilidade: cache negativo do NFS

### O `share s1` (primeira versão)

| Sentido | Leitor começou | Viu o arquivo | "Após a escrita" |
|---|---|---|---|
| a → b | 11:32:45.480 UTC | 11:33:15.480, **+30,000 s** | 25,4 s |
| b → a | 11:33:20.249 UTC | 11:34:20.249, **+60,000 s** | 55,3 s |

O leitor viu o arquivo exatamente 30 s e 60 s **depois do próprio primeiro `stat`**, e não depois da escrita. [SSM: `ExecutionStart`/`End` das invocações]

- O primeiro `stat` de um nome que ainda não existe recebe ENOENT, e o kernel guarda essa resposta (dentry negativa, `lookupcache=all`).
- Ele confia nela até vencerem os atributos em cache do diretório pai: `acdirmin` 30 s, que crescem até `acdirmax` 60 s enquanto o diretório parece não mudar.
- O SSM não entrou na conta: as duas pontas são relógios das instâncias, e o `sleep 3` mais a entrega explicam só a diferença de ~4,7 s entre as duas colunas.

### O experimento controlado (`v-1029-120155`) [vis]

Escritor em a, leitor em b. Os dois começaram no mesmo horário absoluto, recebido 23,6–25,6 s antes, então a entrega do SSM ficou fora da medição. Pelo chrony, os dois clientes estavam em `169.254.169.123` (Amazon Time Sync), com offsets de 0,014 µs e −2,9 µs. Limite de erro de relógio calculado: **1,19 ms**.

| Grupo | n | p50 | p99 | mín | máx | O que é |
|---|---|---|---|---|---|---|
| A (arquivo conhecido, `open`+`read` a cada 10 ms) | 20 | **10,4 ms** | 132,8 ms | 2,1 ms | 156,8 ms | dados novos depois do `close()` do escritor (close-to-open) |
| B-stat (nome novo) | 3 | 22,0 s | 56,3 s | 23 ms | **57,0 s** | brutos: 23 ms, 56.984 ms, 21.988 ms |
| B-open (nome novo) | 3 | 22,0 s | 56,3 s | 14 ms | **57,0 s** | brutos: 14 ms, 56.960 ms, 21.968 ms |
| B-listdir (nome novo) | 3 | **11,5 ms** | 21,8 ms | 9,6 ms | 22,0 ms | brutos: 11, 22, 10 ms |

Latência de cada operação de polling no leitor:

| Operação | n | p50 | p99 | máx | Leitura |
|---|---|---|---|---|---|
| `open`+`read`+`close` (A) | 1.609 | 1,97 ms | 14,5 ms | 235,5 ms | uma ida ao EFS (GETATTR da revalidação) |
| `stat` de nome inexistente (B) | 8.648 | **48 µs** | 122 µs | 5,1 ms | respondido pelo cache, sem rede |
| `open` de nome inexistente (B) | 8.648 | 58 µs | 151 µs | 6,4 ms | idem |
| `listdir` (B) | 442 | 0,91 ms | 3,4 ms | 37,8 ms | vai ao servidor |

O que isso mostra:

- **`stat` e `open` se comportam igual**, slot a slot, com diferença de ~20 ms. É o mesmo mecanismo: o lookup do nome usa a dentry negativa.
- O atraso varia (23 ms, 57 s, 22 s) porque depende de quando vence o cache do diretório, que não tem nada a ver com o momento da escrita. No slot 0, o cache do diretório tinha sido carregado no warm-up (5 s antes do início), **30 s antes da publicação** (início + 25 s): venceu, pelo `acdirmin` de 30 s, logo depois dela.
- **`listdir` viu o nome em 10–22 ms nas três vezes.** Abrir e ler o diretório revalida o diretório no servidor, e a lista vem nova. Era a pergunta aberta do experimento.
- A latência mostra a diferença entre cache e rede: um `stat` respondido pelo cache leva 48 µs, uma ida ao EFS ~1–2 ms. O `stat` "não existe" é barato justamente porque não pergunta nada.
- **Consequência prática:** um app que espera um arquivo novo com `stat` ou `open` em loop pode ficar até `acdirmax` sem vê-lo. Listar o diretório resolve, e montar com `lookupcache=positive` ou `actimeo` menor também, ao preço de mais operações de metadados, cobradas a 4 KiB cada no Elastic. Essa segunda rodada **não foi feita**.

## Concorrência: contador compartilhado [SSM]

Um `send-command` para os dois clientes, cada um com 300 incrementos ler-somar-gravar no mesmo arquivo.

| Modo | Resultado | Tempo por cliente |
|---|---|---|
| `nolock` | **302/600**: 298 updates perdidos | a 6.105 ms, b 6.108 ms (~20 ms por incremento) |
| `lock` (`flock`, fd aberto para escrita) | **600/600** | a 23.705 ms, b 19.900 ms (~66–79 ms por incremento) |

- Sem lock, as duas leituras pegam o mesmo valor e uma escrita apaga a outra. Com 302, quase todo incremento de um cliente foi perdido para o do outro: as duas sequências rodaram em paralelo o tempo todo.
- Com lock, o NFSv4 serializa e o cliente revalida o cache ao pegar o lock, pagando 3–4× mais tempo por incremento.
- No Linux, `flock` sobre NFS vira um lock POSIX do arquivo inteiro. Por isso o fd precisa estar aberto para escrita (`9>>lock`), senão um lock exclusivo falha.

## POSIX, UID/GID, access points e root squash [SSM, `perms`, 11/11 PASS]

| Mount | Teste | Resultado |
|---|---|---|
| `app` (AP, 1001) | root cria um arquivo | dono **1001:1001**, não 0:0 |
| | `nobody` (65534) cria um arquivo | também 1001:1001 |
| | `chown 0:0` | `Operation not permitted` |
| | `chmod` | funciona (1001 é o dono) |
| `root` (IAM, sem AP, sem `ClientRootAccess`) | `stat /lab` | `1001:1001 drwxr-x---` (criado pelo AP) |
| | root grava em `/` | `Permission denied`: root vira 65534 (squash) |
| | root lista `/lab` | `Permission denied` |
| `other` (AP, 1002) | lista `/` | vê `lab` |
| | entra em `/lab` | `Permission denied` |
| | grava em `/` | `Permission denied` |

- **O access point manda na identidade.** Qualquer usuário do cliente, inclusive root, vira o `PosixUser` do AP em toda chamada NFS. É por isso que `chown` falha.
- **Root squash sem access point** vem de **não conceder `ClientRootAccess`** na policy. O root local tem todos os privilégios no kernel, mas o servidor o trata como 65534.
- A simulação IAM (`simulate-principal-policy` com a policy como resource policy) deu:
  - com TLS: `ClientMount` e `ClientWrite` allowed, `ClientRootAccess` implicitDeny;
  - sem TLS: os três explicitDeny;
  - fora de um mount target: implicitDeny.

## Policy contra rede: como cada falha aparece [SSM, CloudTrail]

| Caso | Saída | Tempo | Camada |
|---|---|---|---|
| `try notls` (NFS puro, anônimo) | `mount.nfs4: access denied by server`, exit 32 | **0 s** | POLICY |
| `try noiam` (TLS, anônimo) | `mount.nfs4: access denied by server`, exit 32 | **0 s** | POLICY: só a role está liberada; sem `iam` o cliente é anônimo |
| `net` com a 2049 removida | `TCP 172.31.35.96:2049 no answer in 3 s` | 3 s | NETWORK |
| `try blocked` com a 2049 removida | `Mount attempt 1/3 failed due to timeout after 15 sec` (e 2/3), morto pelo `timeout` | **45 s**, exit 124 | NETWORK |

- A policy **responde e recusa** em menos de 1 s. O SG **não responde** nada: o SYN é descartado. O `efs-utils` 3.3.4 tenta 3 vezes de 15 s cada.
- Antes do teste de rede os dois clientes foram desmontados (umount às 09:35). O teste usou só **conexões novas**, porque o SG é stateful e uma conexão já rastreada continuaria passando. A observação opcional dessa conexão existente não foi feita.
- Do `Revoke` ao `Authorize` passaram 5 min 4 s. Depois do rollback, `net` voltou a `open` e o `probe` passou em 38 e 50 ms. Um `hard` mount não chegou a ser testado durante o bloqueio, porque nada estava montado.
- O isolamento do deny de TLS (`allow_anonymous = true`, passo 7b) **não foi feito**. Hoje, `notls` falha por dois motivos ao mesmo tempo (anônimo e sem TLS).

## Terraform: o `dynamic "ingress"` vazio não removia a regra

- **Sintoma:** com `nfs_ingress_enabled = false`, `terraform plan` dava `No changes`, e o SG `sg-08cd1e321f96d5b8f` seguia com a 2049 (consulta read-only).
- **Causa:** no provider `hashicorp/aws` v6.71.0, `ingress` do `aws_security_group` é **atributo** `optional + computed` (`terraform providers schema -json`). A sintaxe de bloco é só o modo *attributes as blocks*. Um `dynamic` com zero iterações equivale a **não configurar** o atributo, e um atributo computed não configurado mantém o valor que já existe.
- **Correção:** sintaxe de atributo, `ingress = var.nfs_ingress_enabled ? [{ ...todos os campos... }] : []`. A lista vazia explícita remove a regra. Com todos os campos iguais aos do state, `true` dá `No changes`.
- **Resultado:** `false` deu `0 to add, 1 to change, 0 to destroy`, só o SG in-place. O CloudTrail mostra exatamente um `RevokeSecurityGroupIngress` e, no rollback, um `AuthorizeSecurityGroupIngress`.
- Não usei `aws_vpc_security_group_ingress_rule`: exigiria tirar a regra inline do state e importar uma nova, e misturar os dois estilos no mesmo SG gera conflito.
- **Lição:** um toggle precisa ser testado nos dois sentidos com `plan` antes do lab. Um `No changes` onde se esperava mudança é um aviso, não um sinal verde.

## Desempenho: EFS contra gp3 [fio, cliente a, `psync`, `direct=1`]

| Job | EFS | gp3 (raiz, controle) | EFS/gp3 |
|---|---|---|---|
| `seqwrite` 1M QD1, 128 MiB | 29,4 MiB/s, p50 30,8 ms | 292,9 MiB/s, p50 3,3 ms | 10× mais lento |
| `seqread` 1M QD1, 128 MiB | 71,8 MiB/s, p50 13,3 ms | 395,1 MiB/s, p50 1,7 ms | 5,5× |
| `seqwrite-p4` 1M, 4 jobs | **113,9 MiB/s** (3,9× o QD1) | 174,1 MiB/s (menos que o QD1) | 1,5× |
| `randread-4k` QD1, 4.000 ops | 311 IOPS, p50 **3,10 ms**, p99 6,52 ms | 1.712 IOPS, p50 0,59 ms, p99 0,81 ms | 5,3× (p50) |
| `randwrite-4k` QD1 | 93 IOPS, p50 **10,29 ms**, p99 15,14 ms (parou no teto de 30 s com 2.798 ops) | 1.115 IOPS, p50 0,90 ms | 11,4× (p50) |
| 300 × 4 KiB + `fsync` | 4.270 ms (70 arquivos/s) | 1.138 ms (263/s) | 3,8× |
| `ls -l` dos 300 | 27 ms | 5 ms | 5× |
| `rm -rf` dos 300 | 1.870 ms | 7 ms | **267×** |

- **Latência:** o EFS paga uma ida e volta de rede por operação, mais a gravação em várias AZs antes de confirmar. Na escrita 4k a diferença é maior (11×) que na leitura (5×).
- **Paralelismo:** no EFS a vazão cresceu 3,9× com 4 jobs. No gp3 caiu, porque um volume único já estava no limite.
- **Metadados:** o `rm` de arquivos pequenos é o pior caso, uma operação síncrona por arquivo. É o que pega `node_modules`, caches de build e `tar` de muitos arquivos num EFS.

Limitações:

- **Uma rodada, um cliente**, sem repetição nem variância. São ordens de grandeza.
- **Os números sequenciais do gp3 não valem como vazão do gp3:** 293 e 395 MiB/s estão acima dos 125 MiB/s provisionados. Os jobs duraram 0,3–0,4 s, menos que a janela em que o EBS mede o limite. Servem só como "local é bem mais rápido". O Dia 1 mediu o gp3 direito.
- **`seqread` logo depois do `seqwrite`:** o EFS pode ter servido dados ainda quentes no próprio cache. `direct=1` só elimina o cache do cliente.
- **QD1 e no máximo 4 operações em paralelo:** mede latência, não a capacidade do EFS, que escala com muitos clientes e threads.
- **t3.micro:** baseline de rede de 0,064 Gbps, com burst. Os jobs foram curtos o bastante para ficar no burst. CPU média de 0,7–0,8%, então a CPU não foi gargalo [CloudWatch].

## Custo (estimado, preço de tabela us-east-1)

| Item | Cálculo | US$ |
|---|---|---|
| 2 × t3.micro | 2 × 0,0104 × 1,89 h | 0,039 |
| 2 × IPv4 público | 2 × 0,005 × 1,89 h | 0,019 |
| 2 × gp3 8 GiB | 16 × 0,08 / 730 × 1,89 h | 0,003 |
| EFS Standard | pico de 256 MiB [CloudWatch `StorageBytes`] por menos de 1 h | < 0,001 |
| Elastic I/O | piso pelos bytes: 0,258 GiB lidos × 0,03 + (0,383 escritos + 0,055 metadados) × 0,06 | **0,034** (piso) |
| Elastic, pelo mínimo de 32 KiB | os 4.000 `randread` e 2.798 `randwrite` contam 125 + 87 MiB, e não 15,6 + 10,9 MiB | ~+0,01 |
| Surplus de CPU (t3 `unlimited`) | 0 crédito cobrado [CloudWatch] | 0 |
| SSM, mount targets, access points, KMS gerenciada | sem cobrança | 0 |
| **Total** | | **~US$ 0,10** |

Bem abaixo do teto de US$ 1 e do estimado (US$ 0,17 em 4 h), porque o lab durou 1 h 53 min.

O que o CloudWatch não diz:

- `DataReadIOBytes`/`DataWriteIOBytes`/`MetadataIOBytes` contam os bytes que **passaram**, não o mínimo cobrado por operação (32 KiB para dados, 4 KiB para metadados). Por isso são um **piso**.
- `MeteredIOBytes` (0,459 GiB) é a vazão ponderada que o EFS usa para limites de throughput (leitura a 1/3), não a conta.
- O valor cobrado só aparece no Cost Explorer ou no CUR, no dia seguinte. **Pendente de conferir.**

## Falhas e correções do dia

| # | O que aconteceu | Correção |
|---|---|---|
| 1 | O README previa "algumas centenas de ms" para o `share`. Deu 30 e 60 s | Hipótese 1 reescrita: "dados de arquivo conhecido" e "nome novo" são coisas diferentes; README passo 4 |
| 2 | `share s1` repetido às 08:43: os leitores acharam os arquivos da execução anterior em 5–7 ms e deram `OK`, enquanto os escritores falharam (`already exists`). **Falso positivo** | O leitor recusa um arquivo que já existe quando ele começa e confere a tag na primeira linha; tag nova por execução. Testes locais |
| 3 | O timestamp da escrita era tirado antes de gerar o conteúdo | `published_ns` depois do `rename`; `observed_ns` no leitor |
| 4 | Editar o helper mudaria o `user_data`, e o próximo apply (o do SG) pararia e religaria as duas EC2 | `ignore_changes = [ami, user_data]`; o `efs-lab.sh` leva o helper do repo dentro de cada comando SSM, com sha256 conferido. Todos os comandos depois das 09:00 rodaram a cópia `294a5149f07d` |
| 5 | `nfs_ingress_enabled = false` dava `No changes` | `ingress = []` (seção Terraform) |
| 6 | O primeiro teste local do experimento falhou: com slot curto, o prazo da fase B virava zero | Margem `min(1 s, 20% do slot)` |
| 7 | O `clean` às 10:01 apagou `/lab/runs`, inclusive os arquivos do `share s1` que deviam ficar como evidência | Sem consequência: o destroy apagaria de qualquer jeito, e as evidências estão no histórico do SSM (`ssm-outputs.txt`) |

## Limpeza (2026-10-29, conferida só com leitura)

| Recurso | Estado |
|---|---|
| File system `fs-03bf37dc9af454f83` | `FileSystemNotFound`; `describe-file-systems` vazio |
| Access points, mount targets | nenhum; mount targets apagados às 10:06:53 |
| ENIs (inclusive "EFS mount target") | nenhuma na região |
| EC2 a e b | **`terminated`** (User initiated, 13:06:53 GMT). Só aparecem na listagem por cerca de 1 h, e não cobram |
| Volumes EBS, snapshots, EIP | nenhum |
| SGs `sg-08cd1e321f96d5b8f` e `sg-0e83b7ff09ad481a8` | `InvalidGroup.NotFound`; só o `default` |
| AWS Backup | `list-backup-vaults` vazio (nenhum `aws/efs/automatic-backup-vault`), nenhum backup plan. `describe-backup-vault` dá `AccessDenied` ao `readonly-user`: a confirmação é a listagem |
| SSM managed instances | nenhuma |
| `terraform state list` | vazio |
| IAM compartilhado | `lab-storage-ec2-profile` → `lab-storage-ec2-ssm`, só com `AmazonSSMManagedInstanceCore`: **intacto** |
| `scripts/inventory.sh` | **CLEAN** |

Resíduos possíveis: nenhum. As duas instâncias `terminated` não são resíduo.

## Lições

1. **Visibilidade no NFS tem duas faces.** Dados de um arquivo que o cliente já conhece aparecem no próximo `open()` (close-to-open, ~10 ms aqui). Um **nome novo** pode levar até `acdirmax` (60 s) se o cliente já perguntou por ele e ouviu "não existe". `listdir` revalida o diretório e vê na hora.
2. **Medir com o relógio da instância, não com o do orquestrador.** O tempo foi contado a partir do próprio início do leitor, e foi isso que denunciou o cache: 30,000 e 60,000 s redondos.
3. **Um teste que "passa" sem ter rodado é pior que um que falha.** Quem verifica precisa recusar estado velho.
4. **Lock no NFS é obrigatório para ler-somar-gravar entre clientes:** 298 de 600 updates perdidos sem lock.
5. **O access point fixa a identidade, e a policy decide o root.** `chown` falha mesmo como root; sem `ClientRootAccess`, o root vira 65534.
6. **A assinatura separa as camadas:** policy responde e recusa na hora; SG não responde e só o timeout encerra; POSIX deixa montar e nega a operação.
7. **No Terraform, lista vazia não é o mesmo que nenhum bloco** em atributos `optional + computed`. Para remover, escreva `= []`.
8. **O EFS é ~5–11× mais lento por operação que o gp3 e ganha com paralelismo.** Metadados de arquivos pequenos (`rm`, `tar`, `npm install`) são o pior caso.

## Não testado (para uma próxima rodada)

- Passo 7b: `allow_anonymous = true`, para isolar o deny de TLS (`noiam` monta, `notls` continua recusado).
- Passo 10: mount cross-AZ (`MT_IP`) e o custo de US$ 0,01/GB em cada sentido.
- Observar uma conexão NFS já aberta durante o bloqueio do SG (conexão rastreada contra `hard` mount).
- `share` com a versão corrigida (tag nova). A correção só foi testada localmente; o experimento de visibilidade cobriu a medição na AWS.
- Mount options: `lookupcache=positive`, `actimeo`, `noac`, e o custo deles em operações de metadados.
- Concorrência além do contador: append de vários clientes, locks de faixa de bytes, o limite de 512 locks por arquivo.
- Conferir no Cost Explorer o custo real do dia (EC2, IPv4, `TimedStorage` e `ElasticThroughput` do EFS).
