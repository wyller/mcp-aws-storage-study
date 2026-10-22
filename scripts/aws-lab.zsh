# Shell functions to use terraform-lab-role in the current terminal.
# Load them in ~/.zshrc:  source /var/www/mcp-aws-storage-study/scripts/aws-lab.zsh
#
#   aws-lab       asks for the MFA code and exports the role credentials (4h, duration_seconds in [profile lab]) in this terminal
#   aws-lab-off   goes back to readonly-user
#
# The credentials live only in the terminal where you ran it; Claude doesn't see them.

aws-lab() {
  local creds
  # No MFA, no credentials: if the code is wrong, nothing changes in the terminal.
  creds="$(aws configure export-credentials --profile lab --format env)" || return 1
  eval "$creds"
  echo "identity:   $(aws sts get-caller-identity --query Arn --output text --no-cli-pager)"
  echo "expires at: ${AWS_CREDENTIAL_EXPIRATION:-4h}"
}

aws-lab-off() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  echo "identity: $(aws sts get-caller-identity --query Arn --output text --no-cli-pager)"
}
