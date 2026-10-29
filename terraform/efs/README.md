# Day 5: EFS Regional shared by two AZs

Hypotheses:

1. A Regional file system with one mount target per AZ is shared by clients in both AZs. Each client resolves the file system DNS name to the mount target **of its own AZ** (no cross-AZ charge). Two different things become visible on the other client at different speeds:
   - **new data in a file it already knows:** right after the writer's `close()`, on the reader's next `open()` (close-to-open consistency);
   - **a name it does not know yet:** only when the reader's NFS client stops trusting its cached "no such file". With the default mount options that can take up to `acdirmin` 30 s, growing to `acdirmax` 60 s. That is client-side caching, not EFS latency (measured on 2026-10-29, steps 4 and 4b).
2. NFS gives no atomic read-modify-write across clients. Two clients incrementing the same file lose updates. With an NFS lock (`flock`), none are lost, at the cost of one more round trip per update.
3. Access is decided in three layers, each with its own failure signature:
   - **network** (SG on 2049): the mount **hangs** until a timeout;
   - **file system policy** (IAM, TLS): **`access denied by server`**, at once;
   - **POSIX** (access point identity, modes, root squash): the mount works, and the operation returns **`Permission denied`**.
4. EFS latency per operation is several times that of gp3. With QD1 and small files it loses by far. Throughput comes from parallelism, not from one stream.

Run on 2026-10-29 and destroyed the same day (results, evidence and what was not tested: `notas/efs-dia5.md`). Every write to AWS (apply, destroy, SSM session or command) is yours, after `aws-lab`.

## Architecture

```
us-east-1, default VPC vpc-0635f98e4f6eb717e (route 0.0.0.0/0 -> IGW, default NACL, DNS on)

 us-east-1a (use1-az4)                         us-east-1b (use1-az6)
 subnet-0e46a81e8e03686c7                      subnet-0edf5600efd0d7975
┌────────────────────────────┐                ┌────────────────────────────┐
│ lab-efs-client-a t3.micro  │                │ lab-efs-client-b t3.micro  │
│ AL2023, IMDSv2, public IPv4│                │ AL2023, IMDSv2, public IPv4│
│ SG client: no ingress      │                │ SG client: no ingress      │
│ efs-utils: TLS on 127.0.0.1│                │ efs-utils: TLS on 127.0.0.1│
└─────────────┬──────────────┘                └──────────────┬─────────────┘
              │ NFS 4.1 over TLS, TCP 2049                   │
┌─────────────▼──────────────┐                ┌──────────────▼─────────────┐
│ mount target a (ENI)       │                │ mount target b (ENI)       │
│ SG mt: 2049 from SG client │                │ SG mt: 2049 from SG client │
└─────────────┬──────────────┘                └──────────────┬─────────────┘
              └──────────────┐               ┌───────────────┘
                     ┌───────▼───────────────▼───────┐
                     │ EFS Regional "lab-efs"        │
                     │ General Purpose, Elastic      │
                     │ encrypted (aws/elasticfs key) │
                     │ backups DISABLED, no lifecycle│
                     │ policy: lab role + TLS only   │
                     │ /lab  1001:1001 0750          │
                     │ AP app   -> /lab as 1001:1001 │
                     │ AP other -> /    as 1002:1002 │
                     └───────────────────────────────┘
Both clients: Session Manager only, profile lab-storage-ec2-profile (terraform/iam-compartilhado, unchanged)
```

| File | What |
|---|---|
| `main.tf` | 2 SGs, file system, backup policy, 2 mount targets, 2 access points, file system policy, 2 EC2 |
| `files/lab-efs.sh` | on-instance helper (`sudo lab-efs`), installed by cloud-init with `amazon-efs-utils` and `fio` |
| `files/cloud-init.yaml.tftpl` | user data; also writes `/etc/lab-efs.env` (file system and access point IDs, client name) |
| `files/lab-efs-visibility.py` | controlled visibility experiment (step 4b), Python 3.9 stdlib; shipped by `efs-lab.sh visibility`, never installed |
| `tests/lab-efs-guards.sh` | local tests with stubs (no AWS, no NFS): mount guards, `try` rollback, `share` stale/format checks, argument checks |
| `tests/visibility-local.sh` | local run of the visibility experiment on a temp dir (no AWS, no NFS), plus its guards |
| `../../scripts/efs-lab.sh` | local: `status`, `metrics` (readonly); `run`, `share`, `counter`, `visibility` (SSM, after `aws-lab`) |
| `../../scripts/collect-fio.sh` | reused from Day 1: copies `/tmp/lab-fio-*.json` from an instance over SSM |
| `terraform.tfvars` | yours, git-ignored: only the toggles `nfs_ingress_enabled` and `allow_anonymous` |

Choices:

- **Amazon Linux 2023, not Ubuntu.** TLS and IAM mounts need `amazon-efs-utils`, which is in the AL2023 repos. On Ubuntu it is built from source with Rust and cargo, too slow on a 1 GiB t3.micro at first boot. Differences from the earlier labs: `dnf`, user `ec2-user`, and `ssm-user` in the sessions.
- **SSM and dnf over a public IPv4, no NAT and no endpoints.** Same as Day 4: US$ 0.005/h per IPv4. A NAT Gateway (US$ 0.045/h + US$ 0.045/GB) would be ~10x the cost of the lab. The three SSM interface endpoints in two AZs (6 ENIs) would be ~US$ 0.06/h, and dnf would still have no route to the repos. The client SG has no ingress.
- **EFS access through the file system policy, not through the instance role.** The `lab-storage-ec2-ssm` role (shared, unchanged) only has `AmazonSSMManagedInstanceCore`, and `iam simulate-principal-policy` gives `implicitDeny` on `elasticfilesystem:Client*`. For a same-account principal, an allow in the resource policy is enough. So the policy, which is part of this stack and goes away with it, grants `ClientMount` + `ClientWrite` to that role.
- **`ClientRootAccess` not granted:** root on the clients is squashed to 65534 when mounting without an access point. That is the lesson of the `root` mount.
- **Two access points:** `app` (1001:1001, rooted at `/lab`, which it creates with 0750) for every test, and `other` (1002:1002, rooted at `/`) for the denial.
- **Backups explicitly `DISABLED`, no lifecycle policy:** an automatic backup creates recovery points in AWS Backup that a `terraform destroy` does not delete. IA/Archive bill per GB read and per transition.
- **Two toggles, no other variables to change mid-lab:** `nfs_ingress_enabled` (in-place update of the mount target SG) and `allow_anonymous` (in-place update of the policy).
- **`ingress` in attribute syntax, not a `dynamic` block.** In provider 6.x, `ingress` is an `optional + computed` attribute. Zero dynamic blocks means "not set", and the rule stays: `nfs_ingress_enabled = false` planned `No changes` on 2026-10-29. An explicit `ingress = []` removes it.
- **Clients keyed `a`/`b`, AZs from a variable** (`azs`, default `us-east-1a`/`us-east-1b`). `t3.micro` is not offered in `us-east-1e`.
- **t3 `unlimited`, explicit** (it is the account default for t3, checked on 2026-10-29). `standard` would throttle cloud-init and fio to the 20% baseline, because t3 gets no launch credits. The cost is bounded and measured: see "How it bills".
- **The helpers travel inside each SSM command** (gzip + base64, sha256 checked on the instance). `efs-lab.sh` never calls the `/usr/local/bin/lab-efs` that cloud-init installed. What runs is always the reviewed repo copy, whose sha256 shows up in the output. `ignore_changes = [user_data]` keeps an edit of the helper from stopping and starting both clients on the next apply. Each command is ~11 KB (lab-efs) or ~7 KB (visibility).
- **No `/etc/fstab`, no automount:** a stop/start loses the mounts, and nothing tries to mount at boot before the mount targets exist.

## Read-only audit (2026-10-29, `readonly-user`)

| Item | State |
|---|---|
| Identity | `arn:aws:iam::004009722521:user/readonly-user` |
| Inventory | CLEAN at the last session close (2026-10-27 16:59); no EC2, no EFS, only the `default` SG |
| VPC | only the default `vpc-0635f98e4f6eb717e` 172.31.0.0/16; `enableDnsSupport` and `enableDnsHostnames` true (the file system DNS name needs both) |
| Subnets | 6 default subnets (a–f), `MapPublicIpOnLaunch=true`, 4091 free IPs each. Lab: `subnet-0e46a81e8e03686c7` (1a, use1-az4) and `subnet-0edf5600efd0d7975` (1b, use1-az6) |
| Route | main table `rtb-0fc999045f29f7a25`: `0.0.0.0/0 -> igw-0f8b365aa688b01c9`, active |
| NAT Gateway | **none** |
| VPC endpoints | **none** |
| NACL | default `acl-02e92257200f66be6`: allow all in and out (rule 100) |
| t3.micro | offered in 1a, 1b, 1c, 1d, 1f (not 1e) |
| AMI | `al2023-ami-2023.12.20261028.0-kernel-6.1-x86_64` = `ami-08f869bea33461440` (`ignore_changes = [ami]` pins it after the apply) |
| Instance profile | `lab-storage-ec2-profile` -> `lab-storage-ec2-ssm`, only `AmazonSSMManagedInstanceCore` |
| KMS | `alias/aws/elasticfilesystem` exists, `Enabled`, AWS managed |
| EBS encryption by default | off (the stack sets `encrypted = true` on the root volumes) |
| Session Manager preferences | `SSM-SessionManagerRunShell` does not exist: defaults (no logging, no KMS) |
| Local plugin | `session-manager-plugin` 1.2.896.0 on the PATH (missing on Day 4, installed since) |
| Terraform | v1.16.0, provider `hashicorp/aws ~> 6.0` |

## How it bills (us-east-1)

| Item | Price | Idle? | In this lab |
|---|---|---|---|
| t3.micro × 2 | US$ 0.0104/h each | not when stopped | ~4 h |
| Public IPv4 × 2 | US$ 0.005/h each | yes, while allocated | ~4 h |
| gp3 root, 2 × 8 GiB | US$ 0.08/GiB-month | yes | ~4 h |
| EFS Standard storage | US$ 0.30/GB-month, prorated by the hour | **yes**, every byte stored | < 1 GiB, for minutes (perf deletes its files) |
| Elastic Throughput reads | US$ 0.03/GB transferred | no | ≤ 0.25 GiB metered per `perf` run, capped |
| Elastic Throughput writes | US$ 0.06/GB transferred | no | ≤ 0.4 GiB metered per `perf` run, capped |
| t3 `unlimited` surplus | US$ 0.05 per vCPU-hour above the 20% baseline, averaged over the instance's life | no | expected 0; worst case (100% CPU for 4 h) ~US$ 0.36 per instance |
| Metering minimum | each data op counts at least 32 KiB, each metadata op 4 KiB ([docs](https://docs.aws.amazon.com/efs/latest/ug/metered-sizes.html)) | | a 4 KiB write bills as 32 KiB: 8x |
| Mount targets, access points, file system policy, SGs | no charge | | |
| Same-AZ access | no data transfer charge | | the default |
| Cross-AZ access | US$ 0.01/GB in **and** out of the AZ ([pricing](https://aws.amazon.com/efs/pricing/)) | | only the optional step 10, a few KiB |
| KMS `aws/elasticfilesystem` | no monthly fee (AWS managed key) | | |
| Session Manager, Run Command | no charge | | |
| CloudWatch `GetMetricData` | US$ 0.01 per 1,000 metrics requested | | 6 metrics per `metrics` call |

Estimate: ~US$ 0.033/h for the base stack (EC2 + IPv4 + root volumes), plus ≤ US$ 0.03 for the one `perf` run on EFS, plus a few cents for the other tests. **About US$ 0.17 for a 4-hour lab.**

The worst case stays under the US$ 1 target: two `perf` runs forced plus CPU surplus at 100% on both clients would add ~US$ 0.75. That is an estimate from list prices, not a guarantee; the real figure shows up in Cost Explorer the next day. Free tier (5 GB of EFS Standard for 12 months, on eligible accounts) is not counted.

Study only, never enable here:

- **Provisioned Throughput:** billed per MiB/s-month for the whole time it is set, even idle.
- **Lifecycle to IA/Archive:** cheaper storage, but billed per GB read and per transition, with 128 KiB minimum per file.
- **EFS Replication:** storage on both file systems, plus data transfer between Regions.
- **Automatic backups:** recovery points in `aws/efs/automatic-backup-vault`, which `destroy` leaves behind and `inventory.sh` does not count (it skips vaults whose names start with `aws/`).
- **NAT Gateway / interface endpoints:** see "Choices".

What catches you off guard: a perf loop left running (Elastic bills per GB, with no ceiling), many small files (32 KiB minimum per op), a client mounting the mount target of the other AZ (cross-AZ both ways), a backup turned on in the console.

## IAM

No new permissions, and nothing in `iam-compartilhado` changes. Checked with `iam simulate-principal-policy` on 2026-10-29:

| Identity | Needs | Result |
|---|---|---|
| `terraform-lab-role` (`aws-lab`, MFA) | `elasticfilesystem:CreateFileSystem`, `CreateMountTarget`, `CreateAccessPoint`, `PutFileSystemPolicy`, `PutBackupPolicy`, `TagResource`, `Delete*`; `ec2:RunInstances`, `CreateSecurityGroup`, `Authorize/RevokeSecurityGroupIngress`; `ssm:SendCommand`, `StartSession` | allowed (PowerUserAccess) |
| | `iam:PassRole` of `lab-storage-ec2-ssm` to `ec2.amazonaws.com` | allowed |
| `readonly-user` (default) | `elasticfilesystem:Describe*` (file systems, mount targets and their SGs, access points, policy, backup policy, lifecycle), `cloudwatch:GetMetricData`, `ssm:DescribeInstanceInformation`, `terraform plan` | allowed |
| `readonly-user` | `ssm:SendCommand`, `elasticfilesystem:CreateFileSystem` | **denied**: `run`, `share`, `counter`, `collect-fio.sh` and the apply need `aws-lab` |
| `lab-storage-ec2-ssm` (instances) | `elasticfilesystem:ClientMount`, `ClientWrite`, `ClientRootAccess` in its identity policy | `implicitDeny`: granted by the file system policy instead (except root access, on purpose) |
| `claude-cleanup-role` | `elasticfilesystem:DeleteFileSystem`, `DeleteMountTarget`, `DeleteAccessPoint`, `DeleteFileSystemPolicy`; `ec2:TerminateInstances`, `DeleteSecurityGroup` | allowed (`/aws-cleanup` fallback) |

The file system policy (`main.tf`):

- **Allow** `ClientMount` + `ClientWrite` to `lab-storage-ec2-ssm`, only via a mount target.
- **Deny** everything when `aws:SecureTransport` is false.
- **Optional allow** to anonymous clients, when `allow_anonymous = true`.

Once a policy exists, a client mounting without `iam` is **anonymous**, and nothing allows anonymous. Hence `try noiam` is refused even with TLS.

### Effective authorization of `lab-storage-ec2-ssm`

`iam simulate-principal-policy` of the role against this policy (rendered with a placeholder file system ARN, 2026-10-29). The role is not changed:

| Action | TLS, via mount target | no TLS | TLS, not via mount target |
|---|---|---|---|
| `ClientMount` (read-only mount) | **allowed** (resource policy) | explicitDeny | implicitDeny |
| `ClientWrite` | **allowed** (resource policy) | explicitDeny | |
| `ClientRootAccess` | implicitDeny: root squash | explicitDeny | |

What each mount gets, as a result:

| Mount | IAM principal | Server-side identity | Can write |
|---|---|---|---|
| `app` (`tls,iam,accesspoint`) | the role | 1001:1001, forced by the access point; root squash does not matter | yes, under `/lab` (1001 owns it) |
| `other` (`tls,iam,accesspoint`) | the role | 1002:1002, forced by the access point | no: `/` is root's 0755, `/lab` is 0750 |
| `root` (`tls,iam`) | the role | client uid; uid 0 squashed to 65534 (no `ClientRootAccess`) | no, as root |
| `noiam` (`tls`) | anonymous | — | refused at mount, unless `allow_anonymous` |
| `notls` | anonymous, no TLS | — | refused at mount, always |

Access points do not need their own IAM permission: the role mounts through any access point of the file system. To tie the role to one access point, the policy could add the condition `elasticfilesystem:AccessPointArn`. It is not used here, because the `root` mount (no access point) is part of the lab.

### How the tests tell the layers apart

| Layer | Where it fails | Signature | Test |
|---|---|---|---|
| Network (SG, NACL, route, DNS) | before the server answers | **no answer**: `net` says `no answer in 3 s`, the mount hits the 45 s `timeout` (or `Connection timed out`). `RESULT: NETWORK` | `try blocked` with the 2049 rule removed (step 8) |
| IAM / policy (TLS, principal) | at mount time, from the server | **an answer that refuses**, in ~1 s: `access denied by server`. `RESULT: POLICY` | `try notls`, `try noiam` (step 7) |
| Client (options, credentials, efs-utils) | before contacting the server | another error message, at once. `RESULT: CLIENT`; `/var/log/amazon/efs/mount.log` | — (shows up only if something is misconfigured) |
| POSIX (access point identity, modes, root squash) | **after a successful mount**, per operation | `Permission denied` / `Operation not permitted` (EACCES/EPERM). `perms` counts any other error (EIO, timeout) as FAIL | `perms` (step 6) |

What tells them apart is when it fails and how: a network failure takes the whole timeout, a policy failure is an immediate answer, and a POSIX failure needs the mount to have worked. `try` and `perms` check that evidence, not just the exit code.

## Runbook

From the repo root, with `alias tf='terraform -chdir=terraform/efs'`. Before every apply: `plan -out`, read it, then apply **the saved plan**. On the clients, `lab-efs` runs as root through `scripts/efs-lab.sh run a|b|both ...` (SSM Run Command, needs `aws-lab`). The same commands work in a Session Manager shell with `sudo lab-efs ...`.

**Cut rule:** at 3 h 15 min of session, stop and go to the cleanup.

### 0. Before (default profile)

```bash
scripts/inventory.sh                        # CLEAN
tf init && tf plan                          # Plan: 11 to add, 0 to change, 0 to destroy (checked 2026-10-29)
bash terraform/efs/tests/lab-efs-guards.sh terraform/efs/files/lab-efs.sh   # local, no AWS
```

The 11: 2 SGs, file system, backup policy, 2 mount targets, 2 access points, file system policy, 2 EC2.

### 1. Base stack (after `aws-lab`)

```bash
aws-lab                                     # "expires at" ~4 h ahead
tf plan -out day5.tfplan && tf apply day5.tfplan      # mount targets take ~1-2 min to become available
tf output                                   # file_system_id, mount_targets (a/b: AZ and IP), access_point_ids, instance_ids
scripts/efs-lab.sh status                   # works with the default profile too
#   backup policy DISABLED, lifecycle empty, 2 mount targets "available" with the lab-efs-mt SG,
#   2 access points, the policy with LabRoleMountAndWrite and DenyWithoutTls, both clients "Online"
scripts/efs-lab.sh run both status          # cloud-init "done", amazon-efs-utils and fio installed
```

If `run` says the instance is not connected yet, wait 1–2 min: cloud-init installs packages before the agent settles.

### 1b. AWS Console tour (read-only, ~15 min)

Region **N. Virginia (us-east-1)**. Only look: no **Edit**, **Create**, **Delete**, **Attach** or **Connect** in this tour. The console session is whoever logs in, not `aws-lab`. Each screen has what to confirm, and the matching CLI.

| Where | What to confirm | Same as |
|---|---|---|
| **EFS → File systems** | one `lab-efs`: *Regional*, *Elastic*, *General Purpose*, *Encrypted* with `aws/elasticfilesystem`; *Metered size* of a few KiB; *Automatic backups* **Disabled** | `efs-lab.sh status` |
| `lab-efs` → **General** | *Lifecycle management*: none (no IA, no Archive); DNS name `fs-....efs.us-east-1.amazonaws.com` | `describe-lifecycle-configuration` |
| `lab-efs` → **Network** | two mount targets, `us-east-1a` and `us-east-1b`, *Available*, each with its subnet, IP and the `lab-efs-mt-*` SG; the IPs match `tf output mount_targets` | `describe-mount-targets` |
| `lab-efs` → **Access points** | `lab-efs-ap-app`: `/lab`, user 1001/1001, creation 1001/1001 0750; `lab-efs-ap-other`: `/`, user 1002/1002, no creation info | `describe-access-points` |
| `lab-efs` → **File system policy** | the JSON with `LabRoleMountAndWrite` (the role ARN, `AccessedViaMountTarget`) and `DenyWithoutTls`; none of the *Policy options* checkboxes need to change | `describe-file-system-policy` |
| `lab-efs` → **Monitoring** | throughput, IOPS, *Client connections*: flat at 0 until step 3, then 2 | `efs-lab.sh metrics` |
| **EC2 → Instances** (filter `tag:Lab = efs`) | `lab-efs-client-a` in 1a and `-b` in 1b, *Running*, `t3.micro`, *Credit specification* `unlimited`, IMDSv2 *Required*, public IPv4, IAM role `lab-storage-ec2-ssm` | `describe-instances` |
| **EC2 → Security Groups** | `lab-efs-client-*`: no inbound, outbound all. `lab-efs-mt-*`: inbound TCP 2049 **from the client SG** (not a CIDR), and **no outbound rule** | `describe-security-groups` |
| **EC2 → Network interfaces** (filter description `EFS mount target`) | two ENIs, one per AZ, *Requester managed* (by EFS: they go away with the mount targets) | `describe-network-interfaces` |
| **Systems Manager → Fleet Manager** | both instances *Online* (Session Manager is the only way in) | `describe-instance-information` |

What to notice:

- The EFS bill comes from *Metered size* (storage) and from the throughput graphs (Elastic I/O). The mount targets and access points have no price.
- The mount target SG has no outbound rule, and NFS works anyway: the replies follow connection tracking. That is the stateful SG that step 8 depends on.

### 2. DNS and network path

```bash
scripts/efs-lab.sh run both net
```

Expected: each client resolves `fs-....efs.us-east-1.amazonaws.com` to the IP of the mount target **of its own AZ**. Compare with `tf output mount_targets`. Then `TCP ...:2049 open`.

**Hypothesis 1, network part.** If a client resolved to the other AZ, every byte would cost US$ 0.01/GB each way.

### 3. Mount with TLS + IAM and verify

```bash
scripts/efs-lab.sh run both mount app
scripts/efs-lab.sh run both verify app
```

Expected: all checks `PASS`.

- The source is `127.0.0.1:/`: the NFS client talks to the local TLS tunnel (efs-utils, `efs-proxy` or `stunnel` depending on the version), which talks TLS to the mount target on 2049.
- `vers=4.1`, `rsize`/`wsize` 1 MiB, `hard`, `noresvport` are the mount helper defaults.
- `df` shows 8.0E: EFS has no size to provision.
- A file created by root is owned by `1001:1001` on the server: the access point overrides the client identity.

Rollback: `run both umount app`.

### 4. Sharing between AZs (hypothesis 1, new names)

```bash
scripts/efs-lab.sh share                    # a new tag per run (s-MMDD-HHMMSS); never reuse one
```

How it runs, per direction:

1. The reader starts polling with `stat` every 200 ms. If the file is **already there**, it stops: that is a stale file from an earlier run.
2. ~3 s later, the writer publishes 64 KiB of random data: the sha256 first, then the data under a temporary name, renamed into place.
3. The writer prints `published_ns`, taken **after** the rename returns.
4. The reader prints `observed_ns` when `stat` first finds the name. It then checks the first line (tag and client) and the sha256.
5. `efs-lab.sh` prints `observed - published`.

What the number means: the time a **new name** takes to show up on a client that already looked for it and did not find it.

- The reader's first `stat` gets "no such file", and the kernel caches that answer (a negative dentry, `lookupcache=all` by default).
- It trusts it until the cached attributes of the parent directory expire: `acdirmin` 30 s, growing to `acdirmax` 60 s while the directory looks unchanged.
- So the expected value is **0 to 60 s**, decided by the reader's cache, not by EFS.
- The SSM delivery (the `sleep 3` and the agent picking the command up) happens before both instants and is not in it. The clock offset between the clients is (chrony, ~ms).

Measured on 2026-10-29 with the first version of `share s1`:

| Direction | Reader started | Saw it | "after the write" |
|---|---|---|---|
| a → b | 11:32:45.480 | 11:33:15.480, **+30.000 s** | 25.4 s |
| b → a | 11:33:20.249 | 11:34:20.249, **+60.000 s** | 55.3 s |

The reader saw the file exactly when its directory cache expired, counted from **its own** first lookup: the `acdirmin`/`acdirmax` signature. The data itself was correct (sha256).

That first version had two flaws, fixed since:

- **A false pass on a rerun:** at 11:43 `share s1` ran again, the readers "saw" the files of the previous run within 5–7 ms and printed `OK`, while the writers failed with `already exists`. Now the reader refuses a file that is already there, and checks that the file belongs to its tag. The default tag is new on every run.
- **The timestamp:** it was taken before generating the content, not at publication. Now it is `published_ns`, after the rename.

The files of the 11:32 runs stay in `/lab/runs/share-s1` as evidence. Do not `clean` them.

To see the data side, and to compare `stat`, `open` and `listdir` without SSM in the way: step 4b.

### 4b. Controlled visibility experiment

```bash
scripts/efs-lab.sh visibility               # new run name each time (v-MMDD-HHMMSS); ~4 min
```

`efs-lab.sh` sends the script to both clients. Both start at the same wall-clock instant, 30 s ahead, so the SSM delivery is over before the first measurement:

- **The writer (a)** creates `/lab/runs/vis-<run>/` at least 10 s before the start. It refuses a directory that already exists.
- **The reader (b)** does not touch that directory until 5 s before the start, so it never caches a "no such file" for it. At the warm-up it reads the files (positive lookups) and refuses anything but the writer's fresh state.

| Phase | Writer (a) | Reader (b) | Measures |
|---|---|---|---|
| A, 20 × 1 s | rewrites `known.dat` (`seq=i`), `close()`, takes `published_ns` | `open` + `read` + `close` every 10 ms, takes `observed_ns` when `seq=i` first appears | data visibility of a **known** file (close-to-open) |
| B, 3 × 65 s | per slot, renames one new 4 KiB file into each of `b-stat/`, `b-open/`, `b-listdir/`, 3 s after the slot starts | one thread per method, polling from the slot start: `stat` and `open` every 10 ms, `listdir` every 20 ms | how long a **new** name takes, per method. Each method has its own directory, so `listdir` never refreshes the cache `stat` is being measured on |

What it records:

- every event, raw;
- the latency of each poll: a cached `stat` is microseconds, a round trip to EFS is ms;
- `chronyc -c tracking` before and after, on both clients.

`efs-lab.sh` saves both JSONs, the stderr and the analysis in `notas/dados/efs-dia5/vis-<run>/`. The analysis has, per group (A, B-stat, B-open, B-listdir): n, p50, p99, min, max and the raw deltas. Also the sha256 checks of the B files, and a bound for the clock offset: the sum, over both clients, of |system time offset| + root dispersion + root delay / 2.

Limits:

- The schedule is capped at 480 s, A at 50 iterations and B at 5. Polls are never faster than 5 ms.
- Data: 1 file of a few bytes plus 9 files of 4 KiB, kept as evidence.
- Elastic I/O, upper bound:
  - A: ~2,200 opens: GETATTR at 4 KiB, plus 20 reads at 32 KiB;
  - B: up to ~10,000 `listdir` calls at 4 KiB when the directory is revalidated.

  Under 50 MB metered, **< US$ 0.01**.
- No mount options change. `lookupcache=positive`, `actimeo` or `noac` (and their cost in metadata ops) are a later, separate round.

Expected:

- A: tens of ms or less (one GETATTR after the writer's close, plus the 10 ms poll). It can come out slightly negative: the server can serve the data before the writer's `close()` returns.
- B-stat and B-open: 0–60 s, the negative-lookup cache.
- B-listdir: the open question of this experiment. If `opendir` revalidates the directory, it shows up within ms; if it does not, it waits as long as `stat`.

Observed on 2026-10-29 (`v-1029-120155`, clock bound 1.2 ms):

| Group | Result |
|---|---|
| A | p50 10.4 ms, p99 133 ms (n = 20) |
| B-stat | 23 ms, 57.0 s, 22.0 s |
| B-open | 14 ms, 57.0 s, 22.0 s |
| B-listdir | 11, 22, 10 ms: `listdir` revalidates the directory |

A `stat` answered from the cache took 48 µs (p50); a `listdir`, 0.9 ms. Analysis: `notas/efs-dia5.md`.

Not a benchmark:

- p50/p99 of 20 samples (A) and 3 per method (B);
- 10–20 ms poll resolution;
- t3.micro on CPU and network credits.

### 5. Locks (hypothesis 2)

```bash
scripts/efs-lab.sh counter c1 300 nolock    # expected: LOST N update(s)
scripts/efs-lab.sh counter c2 300 lock      # expected: counter c2 = 600: MATCH
```

Both clients get **the same** `send-command`, so they start within about a second. Each increment is an NFS round trip, so the runs overlap. Compare the times: the locked run takes more round trips per update.

If `nolock` happens to show no loss, the runs did not overlap. Repeat with 1000.

Checked locally (two processes on one disk, 2026-10-29): `lock` gave exactly 600, `nolock` lost 566 of 600. On EFS the numbers change, not the conclusion.

Rollback: `run a clean c1`, `run a clean c2`.

### 6. POSIX: access point identity and root squash (hypothesis 3, POSIX layer)

```bash
scripts/efs-lab.sh run a mount other
scripts/efs-lab.sh run a mount root
scripts/efs-lab.sh run a perms              # "0 check(s) differ from the expected"
scripts/efs-lab.sh run a umount other
scripts/efs-lab.sh run a umount root
```

| Mount | Check | Expected |
|---|---|---|
| `app` (AP, 1001) | root creates a file | works, owner `1001:1001` |
| | user `nobody` writes | works, still `1001:1001` |
| | `chown 0:0` | refused |
| | `chmod` | works |
| `root` (no AP, IAM without `ClientRootAccess`) | `stat /lab` | `1001:1001 drwxr-x---` |
| | root writes to `/` | refused: root squashed to 65534, and `/` is root's 0755 |
| | root lists `/lab` | refused (0750) |
| `other` (AP, 1002) | lists `/` | works |
| | enters `/lab` | refused |
| | writes to `/` | refused |

Rollback: `perms` deletes its files, including any that a check that should have failed managed to create.

### 7. File system policy: TLS and IAM (hypothesis 3, policy layer)

```bash
scripts/efs-lab.sh run a try notls          # RESULT: POLICY, "access denied by server", in ~1 s
scripts/efs-lab.sh run a try noiam          # RESULT: POLICY: TLS, but anonymous
```

`notls` fails for two reasons at once: no TLS, and anonymous. To isolate the TLS deny (optional, 2 applies):

```bash
echo 'allow_anonymous = true' >> terraform/efs/terraform.tfvars
tf plan -out anon.tfplan                    # exactly: aws_efs_file_system_policy.lab will be updated in-place
tf apply anon.tfplan
scripts/efs-lab.sh run a try noiam          # RESULT: MOUNTED (rolled back at once): anonymous + TLS is allowed now
scripts/efs-lab.sh run a try notls          # RESULT: POLICY: only the TLS deny is left
```

Rollback (do not skip it):

```bash
sed -i '/allow_anonymous/d' terraform/efs/terraform.tfvars
tf plan -out anon-off.tfplan                # exactly: the policy updated in-place
tf apply anon-off.tfplan
```

`try` never leaves anything mounted: if a mount works, it unmounts it on the spot.

### 8. Network: the SG on 2049 (hypothesis 3, network layer)

Security groups are **stateful**. A tracked connection that already exists keeps working after its rule is removed ([docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/security-group-connection-tracking.html)). So the test **never** relies on an open NFS session breaking. It uses only **new** connections, each with a timeout:

- `net`: a new TCP connection, 3 s;
- `try blocked`: a new mount, with its own TLS tunnel and its own TCP connection, 45 s.

Before (≥ 30 min left on `aws-lab`, so the rollback apply fits in the session). Nothing stays mounted on either client, so no process can hang on a `hard` mount:

```bash
scripts/efs-lab.sh run both umount all
scripts/efs-lab.sh run both net             # baseline: TCP ...:2049 open on both
```

Remove the rule:

```bash
echo 'nfs_ingress_enabled = false' >> terraform/efs/terraform.tfvars
tf plan -out nosg.tfplan
tf show -no-color nosg.tfplan | grep -E '^  # '
#   exactly 1 line: aws_security_group.mount_target will be updated in-place (ingress removed)
#   anything else (e.g. aws_instance.client): do not apply
tf apply nosg.tfplan
```

Test, from **b**:

```bash
scripts/efs-lab.sh run b net                # TCP ...:2049 no answer in 3 s (dropped, not refused). Still "open"? wait 10 s, repeat
scripts/efs-lab.sh run b try blocked        # RESULT: NETWORK after ~45 s; nothing left mounted
```

Compare with step 7: same symptom (no mount), but **~1 s and an answer** there, against **45 s and silence** here. Any `run` that hangs is stopped by SSM after 600 s.

Rollback (right away, even if the test failed):

```bash
sed -i '/nfs_ingress_enabled/d' terraform/efs/terraform.tfvars
tf plan -out sg-on.tfplan                   # exactly: aws_security_group.mount_target updated in-place (ingress back)
tf apply sg-on.tfplan
scripts/efs-lab.sh run both net             # open again on both
scripts/efs-lab.sh run both mount app && scripts/efs-lab.sh run both probe
```

If the `aws-lab` session expires before the rollback: `aws-lab` again, then the same rollback. Nothing is lost meanwhile: no client has EFS mounted.

Optional, only observation (not part of the pass criterion): mount `app` on **a** before removing the rule, and run `run a probe` after. If it still works, that was the tracked connection. If it fails (`did not finish in 10 s`), the connection was reopened, and the `hard` mount blocks until the rollback, without an error. Either outcome is fine; just write it down.

### 9. Performance (hypothesis 4): one run on EFS, from a

| Job | Size / cap | Metered on EFS (upper bound) |
|---|---|---|
| `seqwrite` 1M QD1 | 128 MiB | 128 MiB write |
| `seqread` 1M QD1 | 128 MiB (same file) | 128 MiB read |
| `seqwrite-p4` 1M, 4 jobs | 4 × 32 MiB | 128 MiB write |
| `randread-4k` QD1 | 4,000 ops | 4,000 × 32 KiB = 125 MiB read |
| `randwrite-4k` QD1 | 4,000 ops | 125 MiB write |
| 300 files × 4 KiB, `fsync` each | 300 files | ~13 MiB (data + metadata) |

Every job stops at its size or op count **or at 30 s**, whichever comes first, so a faster or slower EFS never raises the bill. **Upper bound per run: ~0.4 GiB written + ~0.25 GiB read ≤ US$ 0.03.** `lab-efs` allows **one** EFS run per client; a second one needs `PERF_FORCE=1`. The `local` run (root gp3, the control) has no limit and does not touch EFS.

```bash
scripts/efs-lab.sh run a perf efs-a         # on /mnt/efs-app/runs/perf-a, deleted at the end
scripts/efs-lab.sh run a perf local-a local # the same jobs on the root gp3 (/var/tmp)
scripts/efs-lab.sh metrics 60               # default profile: bytes moved, the Elastic cost floor, t3 CPU surplus
```

Expected:

- 4k QD1: p50 of ~1–3 ms on EFS against ~0.5 ms on gp3.
- `seqwrite-p4` above `seqwrite`: parallelism.
- Small files with `fsync`: one to two orders of magnitude slower on EFS.

Read every number against these limits:

- **t3.micro network:** baseline **0.064 Gbps (~7.6 MiB/s)**, bursts up to 5 Gbps on network credits (`describe-instance-types`, 2026-10-29). A run this short stays inside the burst. A long one would fall to the baseline: a client limit, not EFS's (Day 1 lesson).
- **CPU:** 2 vCPUs, 20% baseline. `metrics` shows `CPU avg` and any surplus charged.
- **Cache:**
  - `direct=1` skips the client page cache.
  - EFS may serve recently written data faster than cold data (its own cache, not visible to the client), so `seqread` right after `seqwrite` may be a best case.
  - `randread` stays inside the same 128 MiB file.
  - On gp3, `fsync` and `direct=1` keep the control honest (no page cache).
- **QD and concurrency:**
  - `psync` means one op in flight per job: QD1 measures latency, not capacity.
  - `seqwrite-p4` has 4 in flight; EFS scales with parallel clients and threads, which a single t3.micro does not show.
  - No libaio/iodepth tests: NFS async I/O on Linux does not behave like a block device.
- **One run:** no repetitions, no variance. The numbers are an order of magnitude, not a benchmark.
- **Bill against bytes:** `metrics` shows the bytes moved. The bill is at least that, and up to 8x more for the 4 KiB jobs (32 KiB minimum per op). Metrics take a few minutes to arrive.

Collect **before the destroy**. The JSONs are in `/tmp` and go with the instance:

```bash
scripts/collect-fio.sh <instance_id a> notas/dados/efs-dia5
```

### 10. Optional: cross-AZ mount (cost: a few KiB at US$ 0.01/GB)

In a Session Manager shell on **b** (`aws ssm start-session --target <instance_id b>`):

```bash
sudo lab-efs umount app
sudo MT_IP=<ip of mount target a> lab-efs mount app   # mounttargetip forces the other AZ
sudo lab-efs probe                                    # works, slightly slower
sudo lab-efs umount app && sudo lab-efs mount app     # back to its own AZ
```

The lesson: nothing fails, it just costs more and adds latency. Only the IP in the mount options gives it away.

## Tests and troubleshooting

| Symptom | Hypothesis | Command that confirms it |
|---|---|---|
| `run`: `InvalidInstanceId` / not connected | agent not registered yet, or no route out | `scripts/efs-lab.sh status` (PingStatus); `aws ec2 get-console-output --instance-id ... --latest` |
| `lab-efs: command not found`, `/etc/lab-efs.env missing` | cloud-init still running, or `dnf` failed (no public IPv4, repos down) | `cloud-init status --long`; `/var/log/cloud-init-output.log` |
| `net`: name does not resolve | mount target not `available` yet, or VPC DNS off | `aws efs describe-mount-targets`; `describe-vpc-attribute` |
| `net`: no answer on 2049 | SG of the mount target without the rule (step 8), NACL, or wrong SG on the client | `describe-mount-target-security-groups`; `describe-security-groups` |
| mount hangs, then times out | network (as above). Never IAM: IAM fails at once | `lab-efs net` |
| `access denied by server while mounting` | file system policy: no `iam` (anonymous), no `tls`, or another role | `scripts/efs-lab.sh status` (policy); `aws sts get-caller-identity` on the instance shows `lab-storage-ec2-ssm` |
| `iam` mount: credentials error | instance profile missing, or IMDS hop limit | `aws ec2 describe-iam-instance-profile-associations`; `metadata_options` |
| `accesspoint` mount fails at once with a client error | `accesspoint` requires `tls`; wrong AP ID or another file system | `/var/log/amazon/efs/mount.log` |
| `Permission denied` after a successful mount | POSIX: access point identity, mode of `/lab`, root squash | `stat -c '%u:%g %A' ...`; the access point `PosixUser` |
| `chown` refused on the `app` mount | expected: the access point forces 1001 | step 6 |
| commands hang in `/mnt/efs-*` | hard mount with no path to the server | `lab-efs net`; put the SG rule back (step 8, rollback) |
| `umount`: busy | a process in the directory (also an SSM session `cd`'d there) | `fuser -vm /mnt/efs-app` (the helper prints it) |
| `perf` much slower than expected | t3.micro network credits, or QD1 (latency-bound by design) | `seqwrite-p4` against `seqwrite`; CloudWatch `TotalIOBytes` |
| bill above the bytes in `metrics` | 32 KiB minimum per data op, 4 KiB per metadata op | the 4k jobs and the small files; `MeteredIOBytes` |
| destroy: SG `DependencyViolation` | mount target ENIs still being released | wait; the provider retries. `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<sg>` |
| `nfs_ingress_enabled = false` plans `No changes` | `ingress` written as a `dynamic` block: with zero blocks the computed attribute keeps the AWS value (2026-10-29) | `terraform providers schema -json` (`ingress` is an attribute); `ingress = []` in attribute syntax |
| a reader sees a new file only after 30–60 s | negative lookup cached until the directory attributes expire (`acdirmin`/`acdirmax`) | step 4b: `stat`/`open` slow, `listdir` fast |

Logs on the instance: `/var/log/amazon/efs/mount.log` (mount helper and tunnel), `dmesg | grep -i nfs`.

Local tests, no AWS (stubs):

```bash
bash terraform/efs/tests/lab-efs-guards.sh terraform/efs/files/lab-efs.sh
bash terraform/efs/tests/visibility-local.sh terraform/efs/files/lab-efs-visibility.py
```

They cover:

- writes refused outside an EFS mount through the tunnel: not a mount point, `xfs`, NFS straight to a mount target;
- tags, the env file, an already-mounted target;
- the mount options for `app`, `root` and `MT_IP`;
- `try`: mounted then rolled back, refused, timed out, target still mounted;
- argument checks for `counter`, `share`, `perms` and `perf`.

## Rollback per step

| Step | Changes | Rollback |
|---|---|---|
| 3 | mounts on the clients | `run both umount all` |
| 4, 5 | files under `/lab/runs` | `run a clean <tag>`, or `run a clean` for everything |
| 6 | mounts `other`/`root`; temporary files | `run a umount all`; `perms` deletes its files |
| 7 | (optional) policy with anonymous | remove `allow_anonymous`, plan (1 update), apply |
| 8 | SG without the 2049 rule (nothing mounted meanwhile) | remove `nfs_ingress_enabled`, plan (1 update), apply; `net` open on both; `mount app` + `probe` |
| 9 | ≤ 0.4 GiB written and deleted; JSONs in `/tmp`; the run counter in `/var/lib/lab-efs` | `perf` deletes its directory; `clean` |
| 10 | mount on the other AZ | `umount app` + `mount app` |

## Cleanup checklist

1. Clients: `scripts/efs-lab.sh run both clean` (the second one finds nothing), then `run both umount all`.
2. Terminal (`aws-lab`): `scripts/collect-fio.sh <instance_id a> notas/dados/efs-dia5`, before the destroy.
3. `terraform.tfvars` must be empty or missing (no toggle left at its test value). Default profile: `tf plan -destroy`. Expected: **11 to destroy**:
   - 2 EC2 and 2 SGs;
   - file system, backup policy and file system policy;
   - 2 mount targets and 2 access points.

   Nothing from `iam-compartilhado`: the instance profile is a data source.
4. `aws-lab`: `tf destroy`. Terraform deletes the mount targets before the file system. The mount target SG can take a few minutes, while the ENIs are released.
5. Default profile:
   - `aws efs describe-file-systems --query 'FileSystems[].FileSystemId'`: empty.
   - `aws ec2 describe-instances --filters Name=tag:Lab,Values=efs --query 'Reservations[].Instances[].State.Name'`: only `terminated`.
   - `aws ec2 describe-security-groups --filters Name=group-name,Values='lab-efs-*' --query 'SecurityGroups[].GroupId'`: empty. The inventory does not cover SGs, which do not bill.
   - `aws ec2 describe-network-interfaces --filters Name=description,Values='EFS mount target*' --query 'NetworkInterfaces[].NetworkInterfaceId'`: empty.
   - `aws backup describe-backup-vault --backup-vault-name aws/efs/automatic-backup-vault`: `ResourceNotFoundException` expected (no backup was ever turned on). If it exists, list its recovery points: `inventory.sh` does not count `aws/` vaults.
6. `scripts/inventory.sh`: CLEAN. It covers EFS, EC2, EBS and backup vaults in every region. Whatever is left outside the state goes to `/aws-cleanup`.
7. `rm terraform/efs/*.tfplan terraform/efs/terraform.tfvars`.
8. Keep: `lab-storage-ec2-ssm` and `lab-storage-ec2-profile` (iam-compartilhado).

### Visual check in the Console (read-only, after step 6)

The same region, **N. Virginia (us-east-1)**. Only look, nothing to click besides filters. The Console is a second view, not a replacement for steps 5 and 6.

| Where | Expected |
|---|---|
| **EFS → File systems** | empty (a file system being deleted shows *Deleting* for a minute; refresh) |
| **EFS → Access points** | empty |
| **EC2 → Instances**, filter `tag:Lab = efs` | only *Terminated* (they disappear from the list after ~1 h) |
| **EC2 → Volumes** | no `lab-efs-root-*` (the root volumes go with the instances) |
| **EC2 → Security Groups** | no `lab-efs-client-*` nor `lab-efs-mt-*`; only `default` |
| **EC2 → Network interfaces**, filter `EFS mount target` | empty |
| **EC2 → Elastic IPs** | empty (the stack never used EIPs; the public IPv4s were released with the instances) |
| **AWS Backup → Backup vaults** | no `aws/efs/automatic-backup-vault` |
| **Systems Manager → Fleet Manager** | no `lab-efs` instance *Online* |
| **Billing → Bills** (if the console user has billing access) | next day: EC2, EFS (`TimedStorage`, `ElasticThroughput`) and public IPv4 lines of cents. **Only look**: budgets and billing are not changed by this lab |

## Risks and limitations

- **The SG test (step 8)** runs with nothing mounted, so no process can block on the `hard` mount. The only exception is the optional observation with `app` mounted on a, which can block until the rollback. `net` (3 s), `try` (45 s), `probe` (10 s) and SSM (600 s) all have timeouts. The rollback needs one more apply: start step 8 with ≥ 30 min left on `aws-lab`.
- **Two client instances** double the EC2 and IPv4 cost against the original plan (one client, "< US$ 0.10"). Two are needed to test sharing across AZs.
- **No NAT:** without the public IPv4, cloud-init cannot install the packages and the agent never reaches SSM. The lab depends on `associate_public_ip_address = true` and the IGW route.
- **The performance numbers** come from one capped run, on a t3.micro: baseline network 0.064 Gbps with burst credits, 2 vCPUs at 20% baseline, QD1 and at most 4 ops in flight. They compare EFS with gp3 on this client, not EFS limits (step 9).
- **t3 `unlimited`:** a CPU-heavy mistake (a loop left running) bills surplus at US$ 0.05 per vCPU-hour. `metrics` shows it.
- **The visibility delay** in `share` is sampled every 200 ms, and in step 4b every 10–20 ms, with clocks synced by chrony (bound printed by the analysis). For new names it measures the reader's NFS caches, by design.
- **`nolock` losses** depend on the two runs overlapping; SSM starts both from one call, but does not guarantee the same instant.
- **`metrics` bytes are a floor of the bill**, not the bill (32 KiB / 4 KiB minimums). The real cost only shows up in Cost Explorer the next day.
- **Editing `files/lab-efs.sh` after the apply** no longer touches the instances (`ignore_changes = [user_data]`). The installed `/usr/local/bin/lab-efs` goes stale, but `efs-lab.sh` never uses it. In a Session Manager shell, call `/tmp/lab-efs-repo`, the last shipped copy, instead of `lab-efs`.
- **The SSM command size** (~11 KB with the helper inside) worked locally (decode + sha256), but the Run Command limit on the size of `commands` was not found in the docs. If `send-command` rejects it, the error is immediate and nothing runs on the instance.
- **Access point `/lab` is created on the first mount** through `app`. Step 6 needs step 3 first, or `/lab` does not exist yet for the `root` and `other` checks.
