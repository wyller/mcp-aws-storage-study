# Setup: manual steps

These steps are yours. Claude doesn't create anything in AWS or touch your access.

## In the terminal

```bash
# 1. Python venv (for the boto3 inventory)
sudo apt install -y python3.14-venv

# 2. aws-nuke v3.68.3, with checksum verified
cd "$(mktemp -d)"
v=v3.68.3
curl -sSLO https://github.com/ekristen/aws-nuke/releases/download/$v/aws-nuke-$v-linux-amd64.tar.gz
curl -sSLO https://github.com/ekristen/aws-nuke/releases/download/$v/checksums.txt
grep "aws-nuke-$v-linux-amd64.tar.gz$" checksums.txt | sha256sum -c -
tar xzf aws-nuke-$v-linux-amd64.tar.gz
mkdir -p ~/.local/bin && install -m 755 aws-nuke ~/.local/bin/aws-nuke
aws-nuke version

# 3. MCP image (avoids the wait on first use)
docker pull public.ecr.aws/awslabs-mcp/awslabs/aws-api-mcp-server:1.5.6
```

## In the AWS console (signed in as root, after sorting out MFA)

1. **Delete the root access keys:** account menu → *Security credentials* → *Access keys* → *Actions → Delete* on each one.
2. **Account alias:** IAM → *Dashboard* → *AWS Account* → *Account alias* → *Create* → `wyller-estudos`.
3. **Cleanup policy:** IAM → *Policies* → *Create policy* → *JSON* tab → paste `policies/claude-cleanup-delete-only.json` → name `claude-cleanup-delete-only`.
4. **Cleanup role:** IAM → *Roles* → *Create role* → *Custom trust policy* → paste `policies/claude-cleanup-trust.json` → attach **`ReadOnlyAccess`** and **`claude-cleanup-delete-only`** → name `claude-cleanup-role`. The maximum session duration stays at 1h, the default.

### S3 Replication (Day 3)

`terraform-lab-role` can't create IAM policies, and its PassRole only went to EC2. Replication needs a role that S3 assumes, so:

5. **Replication policy:** IAM → *Policies* → *Create policy* → *JSON* → paste `policies/lab-s3-replication.json` → name `lab-s3-replication`.
6. **Allow-list of the lab role:** IAM → *Policies* → `terraform-lab-iam-lab-roles` → *Edit* → *JSON* → paste `policies/terraform-lab-iam-lab-roles.json` → *Save changes* (it becomes the default version). Done on 2026-10-22 (v2); the repo file is the version in AWS.

## Check

```bash
aws sts get-caller-identity --profile cleanup        # Arn: ...assumed-role/claude-cleanup-role/...
aws iam list-account-aliases                         # wyller-estudos
./scripts/inventory.sh                               # CLEAN
```

Then open Claude Code in `/var/www/mcp-aws-storage-study`, approve the `aws-api` and `aws-knowledge` MCPs and ask for `/aws-cleanup` to test the dry-run.
