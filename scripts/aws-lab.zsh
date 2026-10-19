# Funções de shell para usar a terraform-lab-role no terminal atual.
# Carregue no ~/.zshrc:  source /var/www/mcp-aws-storage-study/scripts/aws-lab.zsh
#
#   aws-lab       pede o código MFA e exporta credenciais da role (1h) neste terminal
#   aws-lab-off   volta para o readonly-user
#
# As credenciais ficam só no terminal onde você rodou; o Claude não as vê.

aws-lab() {
  local creds
  # Sem MFA não há credencial: se o código estiver errado, nada muda no terminal.
  creds="$(aws configure export-credentials --profile lab --format env)" || return 1
  eval "$creds"
  echo "identidade: $(aws sts get-caller-identity --query Arn --output text --no-cli-pager)"
  echo "expira em:  ${AWS_CREDENTIAL_EXPIRATION:-1h}"
}

aws-lab-off() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  echo "identidade: $(aws sts get-caller-identity --query Arn --output text --no-cli-pager)"
}
