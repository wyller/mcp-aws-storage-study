---
name: aws-cleanup
description: Cleans the AWS study account (004009722521) at the end of the day with aws-nuke — dry-run, user confirmation, execution and a report of what's left. Use when the user says /aws-cleanup (or the old /aws-limpar), "clean the account", "limpar a conta", "delete everything in AWS", "não quero gastar à toa".
disable-model-invocation: true
---

# Clean the AWS study account

Deletes everything in account `004009722521`, in every region, except what `nuke-config.yaml` protects (human access, budget, default VPCs). Uses `claude-cleanup-role`, which is only allowed to delete.

Never skip the confirmation, not even when the dry-run is small.

## 1. Pre-checks

Run and check:

```bash
aws sts get-caller-identity --query Account --output text   # 004009722521
aws iam list-account-aliases --query 'AccountAliases[0]' --output text   # wyller-estudos
aws-nuke version
```

If the account or alias don't match, **stop** and tell the user.

## 2. Dry-run

```bash
aws-nuke run --config nuke-config.yaml --profile default \
  --assume-role-arn arn:aws:iam::004009722521:role/claude-cleanup-role \
  --quiet --log-format json > .claude/state/nuke-dry-run.jsonl 2>&1
```

Dry-run is aws-nuke's default, so it deletes nothing. Read the file and summarize for the user:

- a **region → type → count** table of what *would be removed*
- highlight what's billed per hour: EC2, NAT Gateway, Elastic IP, load balancers, RDS, FSx, Transfer, Storage Gateway, interface VPC endpoints
- IAMRole and IAMInstanceProfile named `lab-*` are lab resources (created by Terraform) and may go, **except `lab-s3-read-role`, `lab-storage-ec2-ssm` and `lab-storage-ec2-profile`**: those stay between days. If any of them shows up in the dry-run, **stop**: the filter is wrong
- any other IAM item (IAMUser, IAMRole, IAMPolicy, MFA) or budget, **stop**: the filter is wrong. The role's policy denies touching IAM outside `lab-*`, but the dry-run doesn't know that

If there's nothing to remove, say so and finish.

## 3. Confirmation

Ask with AskUserQuestion: "Delete the N listed resources?", with the options **Delete** and **Cancel**. Only continue on "Delete".

## 4. Execution

```bash
aws-nuke run --config nuke-config.yaml --profile default \
  --assume-role-arn arn:aws:iam::004009722521:role/claude-cleanup-role \
  --no-dry-run --no-prompt --quiet --max-wait-retries 20 \
  --log-format json > .claude/state/nuke-run.jsonl 2>&1
```

The harness also asks for approval here (`--no-dry-run` is under `ask`). The run can take several minutes, and some resources (NAT Gateway, FSx, RDS) are slow to delete.

## 5. Report

1. Run `scripts/inventory.sh` and save the output to `.claude/state/last-inventory.txt`, with `# inventory of <date>` on the first line.
2. List the resources that **failed** in `nuke-run.jsonl`, with the reason. Common causes:
   - **AccessDenied:** the action isn't in `policies/claude-cleanup-delete-only.json`. Say which action is missing. The user decides whether it goes in, and the user updates the policy in the console.
   - **Non-empty Glacier vault:** deleting the archives requires an inventory job (about 24h). Explain that and leave it to the user.
   - **S3 with Object Lock in compliance mode:** can't be deleted before the retention period ends.
   - **KMS:** the key stays in `PendingDeletion` for 7–30 days and isn't billed during that time.
3. End with one line: **account clean**, or **X left: needs manual action**.
