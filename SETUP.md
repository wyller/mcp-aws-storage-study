# Setup: passos manuais

Estes passos são seus. O Claude não cria nada na AWS nem mexe no seu acesso.

## No terminal

```bash
# 1. venv do Python (para o inventário com boto3)
sudo apt install -y python3.14-venv

# 2. aws-nuke v3.68.3, com checksum conferido
cd "$(mktemp -d)"
v=v3.68.3
curl -sSLO https://github.com/ekristen/aws-nuke/releases/download/$v/aws-nuke-$v-linux-amd64.tar.gz
curl -sSLO https://github.com/ekristen/aws-nuke/releases/download/$v/checksums.txt
grep "aws-nuke-$v-linux-amd64.tar.gz$" checksums.txt | sha256sum -c -
tar xzf aws-nuke-$v-linux-amd64.tar.gz
mkdir -p ~/.local/bin && install -m 755 aws-nuke ~/.local/bin/aws-nuke
aws-nuke version

# 3. imagem do MCP (evita a demora no primeiro uso)
docker pull public.ecr.aws/awslabs-mcp/awslabs/aws-api-mcp-server:1.5.6
```

## No console AWS (logado como root, depois de resolver o MFA)

1. **Apagar as access keys do root:** menu da conta → *Security credentials* → *Access keys* → *Actions → Delete* em cada uma.
2. **Alias da conta:** IAM → *Dashboard* → *AWS Account* → *Account alias* → *Create* → `wyller-estudos`.
3. **Policy de limpeza:** IAM → *Policies* → *Create policy* → aba *JSON* → cole `policies/claude-cleanup-delete-only.json` → nome `claude-cleanup-delete-only`.
4. **Role de limpeza:** IAM → *Roles* → *Create role* → *Custom trust policy* → cole `policies/claude-cleanup-trust.json` → anexe **`ReadOnlyAccess`** e **`claude-cleanup-delete-only`** → nome `claude-cleanup-role`. A duração máxima da sessão fica em 1h, que é o padrão.

## Conferir

```bash
aws sts get-caller-identity --profile cleanup        # Arn: ...assumed-role/claude-cleanup-role/...
aws iam list-account-aliases                         # wyller-estudos
./scripts/inventario.sh                              # LIMPO
```

Depois, abra o Claude Code em `/var/www/aws-storage-study`, aprove os MCPs `aws-api` e `aws-knowledge` e peça um `/aws-limpar` para testar o dry-run.
