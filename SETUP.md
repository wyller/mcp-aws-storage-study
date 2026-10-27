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

### Session Manager plugin (Day 4: `aws ssm start-session`)

Ubuntu x86_64 (`dpkg --print-architecture` = `amd64`). Package and signature from the [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-linux-verify-signature.html). Install only if the fingerprint and the signature check out.

```bash
cd "$(mktemp -d)"
base=https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit
curl -sSfo session-manager-plugin.deb     "$base/session-manager-plugin.deb"
curl -sSfo session-manager-plugin.deb.sig "$base/session-manager-plugin.deb.sig"

# AWS public key, copied from the docs page above
cat > session-manager-plugin.gpg <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mFIEZ5ERQxMIKoZIzj0DAQcCAwQjuZy+IjFoYg57sLTGhF3aZLBaGpzB+gY6j7Ix
P7NqbpXyjVj8a+dy79gSd64OEaMxUb7vw/jug+CfRXwVGRMNtIBBV1MgU1NNIFNl
c3Npb24gTWFuYWdlciA8c2Vzc2lvbi1tYW5hZ2VyLXBsdWdpbi1zaWduZXJAYW1h
em9uLmNvbT4gKEFXUyBTeXN0ZW1zIE1hbmFnZXIgU2Vzc2lvbiBNYW5hZ2VyIFBs
dWdpbiBMaW51eCBTaWduZXIgS2V5KYkBAAQQEwgAqAUCZ5ERQ4EcQVdTIFNTTSBT
ZXNzaW9uIE1hbmFnZXIgPHNlc3Npb24tbWFuYWdlci1wbHVnaW4tc2lnbmVyQGFt
YXpvbi5jb20+IChBV1MgU3lzdGVtcyBNYW5hZ2VyIFNlc3Npb24gTWFuYWdlciBQ
bHVnaW4gTGludXggU2lnbmVyIEtleSkWIQR5WWNxJM4JOtUB1HosTUr/b2dX7gIe
AwIbAwIVCAAKCRAsTUr/b2dX7rO1AQCa1kig3lQ78W/QHGU76uHx3XAyv0tfpE9U
oQBCIwFLSgEA3PDHt3lZ+s6m9JLGJsy+Cp5ZFzpiF6RgluR/2gA861M=
=2DQm
-----END PGP PUBLIC KEY BLOCK-----
EOF
gpg --import session-manager-plugin.gpg                     # key 2C4D4AFF6F6757EE
gpg --fingerprint 2C4D4AFF6F6757EE                          # must be 7959 6371 24CE 093A D501  D47A 2C4D 4AFF 6F67 57EE
gpg --verify session-manager-plugin.deb.sig session-manager-plugin.deb   # "Good signature"; "BAD signature": do not install

sudo dpkg -i session-manager-plugin.deb
session-manager-plugin                                      # "...was installed successfully..."
```

The `This key is not certified with a trusted signature` warning is expected: it only means you have not signed the key yourself. The fingerprint check is what validates it. To remove it: `sudo dpkg -r session-manager-plugin`.

## In the AWS console (signed in as root, after sorting out MFA)

1. **Delete the root access keys:** account menu → *Security credentials* → *Access keys* → *Actions → Delete* on each one.
2. **Account alias:** IAM → *Dashboard* → *AWS Account* → *Account alias* → *Create* → `wyller-estudos`.
3. **Cleanup policy:** IAM → *Policies* → *Create policy* → *JSON* tab → paste `policies/claude-cleanup-delete-only.json` → name `claude-cleanup-delete-only`.
4. **Cleanup role:** IAM → *Roles* → *Create role* → *Custom trust policy* → paste `policies/claude-cleanup-trust.json` → attach **`ReadOnlyAccess`** and **`claude-cleanup-delete-only`** → name `claude-cleanup-role`. The maximum session duration stays at 1h, the default.

### S3 Replication (Day 3)

`terraform-lab-role` can't create IAM policies, and its PassRole only went to EC2. Replication needs a role that S3 assumes, so:

5. **Replication policy:** IAM → *Policies* → *Create policy* → *JSON* → paste `policies/lab-s3-replication.json` → name `lab-s3-replication`.
6. **Allow-list of the lab role:** IAM → *Policies* → `terraform-lab-iam-lab-roles` → *Edit* → *JSON* → paste `policies/terraform-lab-iam-lab-roles.json` → *Save changes* (it becomes the default version). Done on 2026-10-22 (v2); the repo file is the version in AWS.

### 4h lab sessions

7. **Lab role session:** IAM → *Roles* → `terraform-lab-role` → *Summary* → *Edit* → *Maximum session duration* → **4 hours** → *Save changes*. Done on 2026-10-22 (`MaxSessionDuration` 3600 → 14400). The role is not in any Terraform stack, so no apply reverts it.
8. **Local profile**, only after step 7, or AssumeRole fails with `ValidationError ... exceeds the MaxSessionDuration`:
   - `~/.aws/config`, `[profile lab]`: `duration_seconds = 3600` → `14400`. MFA (`mfa_serial`) and `source_profile = default` stay as they are.
   - `scripts/aws-lab.zsh` (sourced by `~/.zshrc`) already shows `4h` as the fallback; open a new terminal or `source ~/.zshrc` to load it.
   - `rm -f ~/.aws/cli/cache/*.json`: the CLI keeps reusing the cached 1h session until it expires.

No role chaining: `source_profile = default` is the `readonly-user` IAM user, so the 4h hold. A session started from another role's credentials would be capped at 1h. `aws-lab-off` is unchanged.

## Check

```bash
aws sts get-caller-identity --profile cleanup        # Arn: ...assumed-role/claude-cleanup-role/...
aws iam list-account-aliases                         # wyller-estudos
./scripts/inventory.sh                               # CLEAN
aws iam get-role --role-name terraform-lab-role --query Role.MaxSessionDuration   # 14400
aws-lab                                              # "expires at" ~4h ahead; aws-lab-off returns to readonly-user
```

Then open Claude Code in `/var/www/mcp-aws-storage-study`, approve the `aws-api` and `aws-knowledge` MCPs and ask for `/aws-cleanup` to test the dry-run.
