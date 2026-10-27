# Day 4: EBS snapshots, restore and first-access latency

Hypotheses:

1. Snapshots are incremental: the second one only references the blocks that changed since the first, and deleting the first does not break restoring the second.
2. A snapshot taken while an app writes, with no freeze, is **crash-consistent**: the restored filesystem is in the state a power cut would leave. The journal keeps it valid, and whatever was only in the page cache may be missing.
3. A volume restored from a snapshot is slow on the first read of each block (lazy loading from S3). Reading it all once (initialization) brings it to normal latency.

Nothing here has been applied. Every write to AWS (apply, destroy, SSM session or command, `create-snapshot`) is yours, after `aws-lab`.

## Architecture

```
us-east-1a, default VPC (route 0.0.0.0/0 -> IGW, default NACL)
┌────────────────── EC2 t3.micro (Ubuntu 24.04, IMDSv2, public IPv4, SG with no ingress) ──┐
│  Session Manager only (profile lab-storage-ec2-profile, from terraform/iam-compartilhado)│
│  /dev/sda1  root gp3 8 GiB   /var/lib/lab-ebs: manifests, outside every data snapshot    │
│  /dev/sdf   data gp3 20 GiB  /mnt/lab-data      ──CreateSnapshot──►  snap s1, s2 (S3)    │
│  /dev/sdg   restored gp3     /mnt/lab-restored  ◄──CreateVolume───   one of them         │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

| File | What |
|---|---|
| `main.tf` | EC2, data volume, `aws_ebs_snapshot` per label in `snapshots` (created by Terraform or adopted through `snapshot_ids`), restored volume from `restore_from` |
| `files/lab-ebs.sh` | on-instance helper (`sudo lab-ebs`), installed by cloud-init together with `fio` |
| `files/cloud-init.yaml.tftpl` | user data |
| `tests/lab-ebs-guards.sh` | local test of the device guards, with stubbed `lsblk`/`blkid` (no disk touched) |
| `../../scripts/ebs-snapshots.sh` | local: `status` (readonly), `blocks` and `take` (after `aws-lab`) |
| `terraform.tfvars` | yours, per step, git-ignored: `snapshots`, `snapshot_ids`, `restore_from` |

Choices:

- **SSM over a public IPv4, not VPC endpoints.** The IPv4 is US$ 0.005/h. The three interface endpoints SSM needs would be ~US$ 0.03/h. The SG has no ingress, so nothing listens (see "SSM without ingress").
- **Snapshots in the state.** `destroy` removes them. The frozen snapshot is taken by the CLI, to keep the freeze short, and Terraform adopts it with an `import` block. A snapshot taken any other way is outside the state and keeps billing.
- **Its own stack, not `terraform/ebs`.** The Day 1 stack keeps its fio variables and its earlier `create_snapshot`/`restore_from_snapshot` code (commit `665ce3a`). Never apply both at once: each has its own EC2.
- **Same AZ for everything**, read from the AZ list (Day 1 lesson: reading it from a resource replaced the EC2).
- **Manifests on the root volume**, so a snapshot is never checked against a copy of itself.
- **Volumes found by their ID, never by the device name.** The NVMe serial is the volume ID without the hyphen. `/dev/sdf` does not map to a fixed `nvmeXn1`.

## How it bills (us-east-1)

| Item | Price | Idle? | In this lab |
|---|---|---|---|
| t3.micro | US$ 0.0104/h | not when stopped | ~4 h |
| Public IPv4 | US$ 0.005/h | yes, while allocated | ~4 h |
| gp3 | US$ 0.08/GiB-month, 3000 IOPS and 125 MiB/s included | **yes**, `available` bills the same | 8 + 20 GiB, plus 20 GiB restored for ~2 h |
| Snapshot, standard tier | US$ 0.05/GB-month of the data stored, prorated | yes, until deleted | ~0.4 GB, a few hours |
| EBS direct APIs | US$ 0.0006 per 1000 `ListChangedBlocks`/`ListSnapshotBlocks` | no | a few requests |
| Session Manager, Run Command | no charge | | |

Estimate: ~US$ 0.021/h with the base stack, ~US$ 0.023/h with the restored volume. **About US$ 0.10 for a 4-hour lab.** Snapshot storage is below a cent.

Study only, never enable here:

- **Fast snapshot restore:** US$ 0.75 per DSU-hour, per snapshot and per AZ, with a 1-hour minimum ([pricing](https://aws.amazon.com/ebs/pricing/)).
- **Archive tier:** US$ 0.0125/GB-month, but with a **90-day minimum**, US$ 0.03/GB to restore and 24–72 h of retrieval ([docs](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-archive-pricing.html)).
- **`volume_initialization_rate`:** a provisioned initialization rate, billed extra.

What catches you off guard: a restored volume left `available` after a half-failed apply, a snapshot created outside Terraform, or an AMI (`create-image` creates snapshots that hold it). A Recycle Bin rule would keep deleted snapshots and keep billing for them, and `describe-snapshots` would no longer show them. **No rule exists today** (checked on 2026-10-27).

### Changed blocks are not the bill

- `ListSnapshotBlocks` counts the blocks a snapshot **references**, including blocks it shares with older snapshots. `ListChangedBlocks` counts the blocks that **differ** between two snapshots of the same lineage. Both use 512 KiB blocks.
- The bill is for the data **stored**: blocks referenced by several snapshots are stored and billed once. A block only counts as changed if it was written, even with the same bytes. Partial writes inside a 512 KiB block count as the whole block.
- When s1 is deleted, the blocks s2 still needs stay stored and are billed to s2. Only the blocks nobody references go away ([docs](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-deleting-snapshot.html)).
- `FullSnapshotSizeInBytes` is the size of all the blocks written to the volume when the snapshot was taken, not the increment ([boto3](https://docs.aws.amazon.com/boto3/latest/reference/services/ec2/snapshot/full_snapshot_size_in_bytes.html)).
- The billed amount per snapshot only shows up in Cost Explorer or the CUR (resource level), the next day. In this lab it rounds to zero.
- Pagination: the CLI has no paginator for these APIs. One call returns at most `MaxResults` (100 to 10,000), so `blocks` follows `NextToken` until it disappears, and reports the number of pages.

## IAM

No new permissions. Checked with `iam simulate-principal-policy` on 2026-10-27:

| Identity | Needs | Result |
|---|---|---|
| `terraform-lab-role` (`aws-lab`, MFA) | `ec2:RunInstances`, `CreateVolume`, `AttachVolume`, `CreateSnapshot`, `DeleteSnapshot`, `CreateTags`, `DescribeSnapshots`; `ebs:ListChangedBlocks` | allowed (PowerUserAccess) |
| | `iam:PassRole` of `lab-storage-ec2-ssm`, with `iam:PassedToService = ec2.amazonaws.com` | allowed (`PassRoleSoParaEC2`). To `ssm.amazonaws.com` it is **denied**, and nothing here needs it |
| | `ssm:StartSession` (instance and `SSM-SessionManagerRunShell`), `ssm:SendCommand` (instance and `AWS-RunShellScript`), `GetCommandInvocation`, `TerminateSession`, `ResumeSession` | allowed (PowerUserAccess) |
| `readonly-user` (default) | `ec2:Describe*`, `ssm:DescribeInstanceInformation`, `terraform plan` (including the import lookup) | allowed |
| `readonly-user` | `ebs:ListChangedBlocks`, `ebs:ListSnapshotBlocks`, `ssm:SendCommand` | **denied**: `blocks`, `take` and `collect-fio.sh` run after `aws-lab` |
| `lab-storage-ec2-ssm` (instance) | `ssm:UpdateInstanceInformation`, `ssmmessages:*Channel`, `ec2messages:GetMessages` | allowed (`AmazonSSMManagedInstanceCore`) |
| `lab-storage-ec2-ssm` | `ec2:CreateSnapshot`, `ebs:*` | denied, on purpose: snapshots come from your terminal |
| `claude-cleanup-role` | `ec2:DeleteSnapshot`, `DeleteVolume`, `DetachVolume`, `TerminateInstances`, `DeleteSecurityGroup` | allowed (`/aws-cleanup` fallback) |

What could be tighter, but stays as is (shared roles are not changed here): PowerUserAccess gives `ssm:SendCommand` on any instance and document. For this lab, `AWS-RunShellScript` on instances with `Lab=ebs-snapshots` would be enough.

**Session length:** `terraform-lab-role` has `MaxSessionDuration` 14400, and `[profile lab]` has `duration_seconds = 14400`, with `source_profile = default` (an IAM user, so no role chaining and no 1-hour cap). Checked on 2026-10-27. The real confirmation is the `expires at` line `aws-lab` prints: it must be ~4 h ahead. `take` refuses to run with less than 15 min left.

## SSM without ingress

The agent opens outbound HTTPS to `ssm`, `ssmmessages` and `ec2messages` and keeps the channel open. Session Manager never connects in, so the SG needs no ingress. Checked on 2026-10-27 (read-only):

| Requirement | State |
|---|---|
| Public IPv4 | default subnet `subnet-0e46a81e8e03686c7` (us-east-1a) with `MapPublicIpOnLaunch=true`, and `associate_public_ip_address = true` in the stack |
| Route out | main route table: `0.0.0.0/0 -> igw-0f8b365aa688b01c9`, active |
| NACL | default: allow all in and out (rule 100), so the return traffic on ephemeral ports gets through |
| DNS | `enableDnsSupport` and `enableDnsHostnames` true |
| SG | egress all; ingress none |
| VPC endpoints | none (not needed with the IGW) |
| Instance role | `AmazonSSMManagedInstanceCore` |
| IMDSv2 required | supported by the agent that ships with Ubuntu 24.04 (snap) |
| Session preferences | `SSM-SessionManagerRunShell` does not exist, so the defaults apply (no logging, no KMS) |
| Local plugin | **`session-manager-plugin` is not on the PATH of this machine.** Install it before `start-session`, or use the console: EC2 → instance → *Connect* → *Session Manager* |

Only the apply proves it works: `describe-instance-information` showing `PingStatus=Online` is the confirmation.

## Runbook

From the repo root, with `alias tf='terraform -chdir=terraform/ebs-snapshots'` (zsh does not split a `$tf` variable). Before every apply: `plan -out`, read it, then apply **the saved plan**. When the plan destroys something you did not expect, a variable is missing from `terraform.tfvars`.

### 0. Before (default profile, in Claude Code or in your terminal)

```bash
scripts/inventory.sh                        # CLEAN
tf init && tf plan                          # Plan: 4 to add (SG, EC2, data volume, attachment)
```

### 1. Base stack (after `aws-lab`)

```bash
aws-lab                                     # "expires at" ~4 h ahead
tf plan -out day4.tfplan && tf apply day4.tfplan
tf output                                   # instance_id, data_volume_id
aws ssm describe-instance-information --filters Key=InstanceIds,Values=<instance_id> \
  --query 'InstanceInformationList[].PingStatus'        # "Online" after ~1-2 min
aws ssm start-session --target <instance_id>            # or the console
```

On the EC2: `cloud-init status --wait` (`done`), then `sudo lab-ebs` prints the usage.

### 2. Data volume and dataset (EC2)

```bash
sudo lab-ebs status                         # nvme0n1 = root (with partitions), the data volume with no filesystem
sudo lab-ebs prepare <data_volume_id>       # ext4 on /mnt/lab-data
sudo lab-ebs seed                           # ~260 MiB: 4 x 64 MiB + 1000 x 4 KiB, random
sudo lab-ebs manifest s1                    # /var/lib/lab-ebs/s1.sha256: 1004 files
```

`prepare` refuses:

- the disk that holds `/`;
- a disk with partitions;
- a device that is not EBS;
- anything mounted;
- a device with any signature (`blkid -p`: a partition table or another filesystem). An ext4 device is only mounted, never formatted again.

### 3. s1, consistent at the filesystem level: freeze → CreateSnapshot → thaw (your terminal, `aws-lab`)

The point in time is the `CreateSnapshot` call, and the volume can be used again once the snapshot is `pending` ([docs](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-creating-snapshot.html)). The freeze therefore only has to last until AWS returns the snapshot ID.

**Why not with `terraform apply`:** the apply prints `Creating...` *before* the call and then only `Still creating... [10s elapsed]`. Nothing shows when AWS accepted the snapshot. The freeze would last at least ~10 s, by eye. And if the apply failed before the call (expired credentials, a lock, the provider), the freeze would last until the auto-thaw.

So the CLI takes the snapshot and Terraform adopts it:

```bash
scripts/ebs-snapshots.sh take s1
```

What it does:

1. **Preflight**, before freezing anything:
   - you are `terraform-lab-role`, with ≥ 15 min of session left;
   - no lab snapshot named `s1` exists;
   - no `pending` snapshot on the volume (it would stack behind it);
   - the instance is `Online` in SSM.
2. `lab-ebs freeze 60` over SSM, with an auto-thaw on the instance after 60 s (covers the script, the network or the session dying).
3. `ec2 create-snapshot`, with the same description and tags as `aws_ebs_snapshot.data`.
4. `lab-ebs thaw` over SSM, right after the ID comes back. A `trap` sends the thaw too if step 3 fails.
5. Prints the `frozen at` / `thawed at` timestamps (the freeze duration, measured) and the lines for the tfvars.

Expected: a freeze of a few seconds (the SSM round trips are polled every 0.5 s), and `thawed at ...; /mnt/lab-data was frozen`.

Adopt it into the state:

```bash
cat > terraform/ebs-snapshots/terraform.tfvars <<'EOF'
snapshots    = ["s1"]
snapshot_ids = { s1 = "snap-..." }
EOF
tf plan -out s1.tfplan                      # Plan: 1 to import, 0 to add, 0 to change, 0 to destroy
tf apply s1.tfplan
```

**If the plan shows a change or a replace** on `aws_ebs_snapshot.data["s1"]` instead of an import alone, do not apply. A tag or the description drifted from the script. An in-place tag update is harmless. A replace would take a new snapshot without the freeze.

### 4. Change the data and take s2 with the app writing, no freeze (crash-consistent, through Terraform)

```bash
sudo lab-ebs mutate                         # EC2: 8 MiB overwritten, 100 files deleted, 32 MiB new
sudo lab-ebs manifest s2                    # 905 files
sudo lab-ebs writer start                   # appends dozens of records/s to /mnt/lab-data/app/journal.log, no fsync
```

```bash
cat > terraform/ebs-snapshots/terraform.tfvars <<'EOF'
snapshots    = ["s1", "s2"]
snapshot_ids = { s1 = "snap-..." }
EOF
tf plan -out s2.tfplan                      # 1 to add (s2); s1 untouched
tf apply s2.tfplan
sudo lab-ebs writer stop                    # EC2, after the apply
```

Write down the `StartTime` of s2 (`scripts/ebs-snapshots.sh status`).

### 5. Measure the increment (your terminal, `aws-lab`)

```bash
scripts/ebs-snapshots.sh blocks <s1>        # blocks s1 references: ~ dataset + ext4 metadata
scripts/ebs-snapshots.sh blocks <s1> <s2>   # different between them, split into new and rewritten
```

Expected: the second number is a small part of the first (~40 MiB plus metadata and the journal), and the deletes add no data blocks. These are **counts of blocks, not the bill** (see "Changed blocks are not the bill").

### 6. Restore s1: first-access latency and integrity

```bash
cat > terraform/ebs-snapshots/terraform.tfvars <<'EOF'
snapshots    = ["s1", "s2"]
snapshot_ids = { s1 = "snap-..." }
restore_from = "s1"
EOF
tf plan -out r1.tfplan && tf apply r1.tfplan     # 2 to add (restored volume + attachment)
```

On the EC2, **in this order** (every read initializes the blocks it touches):

```bash
sudo lab-ebs status                                       # the restored volume has the same ext4 UUID and label as the source
sudo lab-ebs mount <restored_volume_id> /mnt/lab-restored ro
sudo lab-ebs latency restored-cold                        # 1st: blocks still in S3
sudo lab-ebs verify s1                                    # OK: 1004 files, no extra
sudo lab-ebs init <restored_volume_id>                    # reads all 20 GiB (several minutes)
sudo lab-ebs latency restored-warm
sudo lab-ebs latency source /mnt/lab-data                 # control: never restored
```

Expected: `restored-cold` with p99 well above `restored-warm`, and `restored-warm` close to `source`. Not a promise: the size of the difference is what the lab measures.

### 7. Swap the restore to s2 and delete s1: without detaching a mounted volume

Three applies, each with its own plan, so no detach ever happens with the volume mounted:

```bash
# EC2
sudo lab-ebs umount /mnt/lab-restored
sudo lab-ebs detach-ready <restored_volume_id>            # must print READY; anything else: do not go on
```

```bash
# a) only detaches and deletes the restored volume
cat > terraform/ebs-snapshots/terraform.tfvars <<'EOF'
snapshots    = ["s1", "s2"]
snapshot_ids = { s1 = "snap-..." }
EOF
tf plan -out r0.tfplan     # 2 to destroy: aws_volume_attachment.restored[0], aws_ebs_volume.restored[0]
tf apply r0.tfplan

# b) deletes s1 (and drops it from snapshot_ids)
echo 'snapshots = ["s2"]' > terraform/ebs-snapshots/terraform.tfvars
tf plan -out d1.tfplan     # 1 to destroy: aws_ebs_snapshot.data["s1"]
tf apply d1.tfplan

# c) restores s2
printf 'snapshots    = ["s2"]\nrestore_from = "s2"\n' > terraform/ebs-snapshots/terraform.tfvars
tf plan -out r2.tfplan     # 2 to add
tf apply r2.tfplan
```

```bash
# EC2
sudo lab-ebs mount <restored_volume_id> /mnt/lab-restored ro     # new ID: tf output restored_volume_id
sudo lab-ebs verify s2                                           # OK even with s1 deleted
sudo lab-ebs writer check /mnt/lab-restored <StartTime of s2>
sudo lab-ebs writer check /mnt/lab-data                          # everything the app wrote
```

Expected, and how to read it:

- **`verify s2` OK:** deleting a snapshot only removes the blocks no other snapshot references.
- **`writer check` on the restored volume**, a valid result either way:
  - fewer records than on the source;
  - possibly a gap between the last record and the StartTime;
  - possibly a `bad` partial last line;
  - or nothing lost at all, if the kernel had flushed it all just before.

  It is the evidence of what a crash-consistent snapshot captured, not a test with one right answer. Writeback timing (ext4 commit every 5 s by default, dirty pages flushed after ~30 s) decides how much made it.
- **On the mount**, dmesg may or may not mention the journal: whether a replay is needed depends on what was in flight. Do not take its absence as a sign of an error.
- **`blocks <s2>`** now counts everything s2 references. The storage of the blocks it shared with s1 stays billed, now to s2.

### 8. Collect and clean up

See the checklist below.

## Filesystem consistency and active apps

| Level | How | What it guarantees |
|---|---|---|
| Crash-consistent | snapshot with no pause (step 4) | the same as a power cut: the journal keeps the filesystem valid, but data in the page cache or in the app's memory may be missing |
| Filesystem-consistent | `fsfreeze -f` until `pending`, then `-u` (step 3); or unmount | everything the kernel had is on disk, but an app may be halfway through its own transaction |
| Application-consistent | the app flushes and pauses (e.g. `FLUSH TABLES WITH READ LOCK`, `pg_backup_start`), then freeze | the app restarts without its own recovery. In AWS: Data Lifecycle Manager or AWS Backup with SSM pre/post scripts ([blog](https://aws.amazon.com/blogs/storage/automating-application-consistent-amazon-ebs-snapshots-for-mysql-and-postgresql/)) |

Risks:

- **A freeze blocks the app's writes.** Writes to `/mnt/lab-data` hang until the thaw. In production that means timeouts. That is why the freeze lasts as long as one API call, with an auto-thaw.
- **Never freeze `/`.** The SSM agent and journald write there, and the session could hang with nothing left to thaw it. `lab-ebs freeze` only freezes `/mnt/lab-data`. AWS recommends stopping the instance to snapshot a root volume.
- **Several volumes (LVM, RAID, DB data plus WAL on separate volumes):** one snapshot per volume yields different points in time. Use a multi-volume snapshot (`create-snapshots --instance-specification`), which is crash-consistent across the volumes.
- **Stacked snapshots:** a new snapshot of the same volume stays `pending` at 0% until the previous one finishes. Deleting a `pending` snapshot does not cancel it ([re:Post](https://repost.aws/knowledge-center/ebs-snapshot-ec2-ami-creation-slow)). `take` refuses if one is pending.
- **Restored volume in production with no initialization:** latency spikes on the first access. Initialize it, or pay for FSR.
- **Same UUID:** a restored volume has its source's UUID and label. An `/etc/fstab` with `UUID=` or `LABEL=` can mount the wrong one after a reboot. XFS refuses the duplicate mount (`-o nouuid`), and ext4 accepts it silently.
- **Detaching a mounted volume:** it can stay `busy` indefinitely until it is unmounted, rebooted or force-detached. A force detach can corrupt it ([docs](https://docs.aws.amazon.com/boto3/latest/reference/services/ec2/client/detach_volume.html)). Hence `detach-ready` and the separate apply in step 7.
- **Encryption:** snapshots with the `aws/ebs` key cannot be shared with another account (that needs a customer managed key). The account has snapshot block public access `unblocked`. Not a risk in this lab, because nothing gets shared, but `block-all-sharing` is free hardening (an account setting: your decision).

## Tests and troubleshooting

| Symptom | Hypothesis | Command that confirms it |
|---|---|---|
| `start-session`: `SessionManagerPlugin is not found` | local plugin missing | install `session-manager-plugin`, or use the console |
| `start-session`: `TargetNotConnected` | agent has not registered yet, or has no route out | `aws ssm describe-instance-information`; `aws ec2 get-console-output --instance-id ... --latest` |
| `lab-ebs: command not found` | cloud-init still running or failed | `cloud-init status --long`; `/var/log/cloud-init-output.log` |
| `volume ... is not attached` | attachment still `attaching`, or wrong ID | `aws ec2 describe-volumes --volume-ids ... --query 'Volumes[].Attachments'`; `lsblk -o NAME,SERIAL` |
| `prepare`: "holds /", "has partitions", "signature" | wrong volume ID (the root's, or a restored one) | `sudo lab-ebs status`; `tf output data_volume_id` |
| `seed`: "not a mount point" | volume not mounted (Day 1: fio wrote to root) | `findmnt -T /mnt/lab-data` |
| Commands hang in `/mnt/lab-data` | still frozen | `sudo lab-ebs thaw` |
| `take`: "pending snapshot" | a previous snapshot is still copying | `scripts/ebs-snapshots.sh status` (`Progress`) |
| `take`: "session ends in N min" | `aws-lab` session close to expiring | `aws-lab` again |
| Plan of step 3 shows a replace of `s1` | description or tags differ from the script | do not apply; compare `describe-snapshots` with `main.tf` |
| Apply stuck on `aws_ebs_snapshot` | snapshot `pending`, or a large first snapshot | `status`; 30 min timeout |
| Apply stuck destroying `aws_volume_attachment.restored` | volume still mounted, detach in `busy` | on the EC2: `sudo lab-ebs umount /mnt/lab-restored`; the detach finishes on its own. Never force detach |
| `mount`: `wrong fs type` | restored from a snapshot taken before `prepare` | `blkid -p /dev/nvmeXn1`; the `RestoredFrom` tag |
| `verify` fails or shows extra files | wrong manifest/snapshot pair (s1 vs s2) | the volume's `RestoredFrom` tag against the label passed |
| `blocks`: `AccessDeniedException` | ran with `readonly-user` | expected; run after `aws-lab` |
| `InvalidVolume.ZoneMismatch` | volume in another AZ (the stack does not allow this; it only happens in the CLI) | `describe-volumes` against `describe-instances` |
| cold ≈ warm | blocks already read (by `verify`, a previous run or `init`) | redo step 6 in order, on a new restore |

Local test of the guards, with no AWS and no disk: `bash terraform/ebs-snapshots/tests/lab-ebs-guards.sh terraform/ebs-snapshots/files/lab-ebs.sh`.

## Cleanup checklist

1. EC2:
   - `sudo lab-ebs writer stop; sudo lab-ebs thaw`
   - `sudo lab-ebs umount /mnt/lab-restored && sudo lab-ebs detach-ready <restored_volume_id>`: READY.
2. Terminal (`aws-lab`): `scripts/collect-fio.sh <instance_id> notas/dados/ebs-dia4` (fio JSONs, checked by sha256).
3. Default profile: `tf plan -destroy`. Expected with the step 7 tfvars: **7 to destroy**:
   - SG and EC2;
   - data volume and its attachment;
   - snapshot s2;
   - restored volume and its attachment.

   Nothing from `iam-compartilhado`.
4. `aws-lab`: `tf destroy`. The data attachment stops the EC2 before detaching. The root volume goes with the instance.
5. Default profile:
   - `scripts/ebs-snapshots.sh status`: no snapshot and no volume.
   - `aws ec2 describe-instances --filters Name=tag:Lab,Values=ebs-snapshots --query 'Reservations[].Instances[].State.Name'`: only `terminated`.
   - `aws ec2 describe-security-groups --filters Name=group-name,Values='lab-ebs-snap-*' --query 'SecurityGroups[].GroupId'`: empty. The inventory does not cover SGs, which do not bill.
   - `aws rbin list-rules --resource-type EBS_SNAPSHOT`: still empty (otherwise deleted snapshots stay billed, out of `describe-snapshots`).
6. `scripts/inventory.sh`: CLEAN. It covers, in every region, non-terminated instances, volumes (any state), own snapshots, own AMIs and EIPs. Whatever was left outside the state goes to `/aws-cleanup`.
7. `rm terraform/ebs-snapshots/*.tfplan terraform/ebs-snapshots/terraform.tfvars`.
8. Keep: `lab-storage-ec2-ssm` and `lab-storage-ec2-profile` (iam-compartilhado).
