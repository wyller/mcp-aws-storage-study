# Estudos de storage na AWS

Conta de estudos `004009722521` (alias `wyller-estudos`), região padrão `us-east-1`. O objetivo é prática para entrevistas e trabalho DevOps: troubleshooting real e noção de custo. Não é decoreba de certificação.

## Regras

- **Nunca crie, altere ou inicie nada na AWS.** Diagnostique (leia configs, logs, métricas e policies) e passe o comando ou o caminho no console. Quem executa é o usuário.
- **Nunca mexa no acesso humano:** root, `readonly-user` (chaves, policies, MFA), budget e billing.
- Ler: use o MCP `aws-api` (só leitura) ou `aws ... describe/list/get` com o profile default.
- Documentação: use o MCP `aws-knowledge` antes de responder de memória. Cite o link.
- Apagar: o caminho principal é `terraform destroy`, que o usuário roda com `aws-lab`. Antes, rode `terraform plan -destroy` com o profile default e confira o que sai. Para o que ficou fora do state (criado no console, apply que falhou no meio), use a skill `/aws-limpar`. Nada de `delete-*` avulso.
- Depois de qualquer limpeza, rode `scripts/inventario.sh` para confirmar que não sobrou nada cobrando.

## Identidades

| Profile | Identidade | Pode |
|---|---|---|
| `default` | `readonly-user` | ler; tem também `CustomS3CreateBucket`/`DeleteBucket` (é acesso humano) |
| `cleanup` | `claude-cleanup-role` | ler e apagar; sessão de 1h; nega identidades protegidas, `lab-s3-read-role` e billing |
| `lab` | `terraform-lab-role` | criar (PowerUser + roles `lab-*`); exige MFA; **só o usuário usa**, via `aws-lab` |

## Ajudando nos estudos

- Ao explicar um serviço, inclua **como ele cobra**: o que conta por hora, o que conta por GB e o que conta mesmo parado.
- No troubleshooting, mostre o raciocínio: hipótese → comando que confirma → o que o resultado significa.
- Anotações do usuário ficam em `notas/`. Proponha escrever lá quando surgir um aprendizado que vale guardar.

## Arquivos

- `nuke-config.yaml`: o que a limpeza protege.
- `policies/`: as policies da `claude-cleanup-role`, coladas pelo usuário no console.
- `scripts/inventario.sh`: lista rápida do que custa em todas as regiões. Roda sozinho ao abrir e ao fechar a sessão.
- `SETUP.md`: passos manuais do usuário no console.
