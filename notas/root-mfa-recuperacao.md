# Root sem MFA: recuperação e higiene da conta

## O que é e quando usar

Se o dispositivo de MFA do root some (celular trocado, app apagado), a AWS deixa entrar por **fatores alternativos**:

1. Tela de MFA → *Trouble signing in?* → *Sign in using alternative factors*.
2. **E-mail:** chega um link no e-mail do root. Vale por 15 minutos e só pode ser usado uma vez.
3. **Telefone:** a AWS liga para o **telefone de contato principal da conta** (*Account → Contact information*), não para o celular onde estava o MFA. Você digita no teclado do celular o código que aparece na tela.
4. Depois de entrar, em *Security credentials*: remover o MFA antigo e cadastrar um novo na hora.

Se você não tem mais esse telefone, não há saída pelo console. É preciso abrir um chamado no formulário de MFA do suporte, que pede o **Account ID**. Errar esse número atrasa tudo.

Docs:
- https://repost.aws/knowledge-center/reset-root-user-mfa
- https://repost.aws/knowledge-center/troubleshoot-mfa-root-user-failures

## Como cobra

- IAM, MFA e alias não custam nada.
- O custo está no risco: uma **access key de root ativa** dá controle total da conta, sem MFA. Se vazar, alguém sobe instâncias de mineração em todas as regiões e a fatura chega para você.
- A AWS recomenda não ter access key no root. `aws iam get-account-summary` mostra `AccountAccessKeysPresent` (tem que ser 0) e `AccountMFAEnabled` (tem que ser 1).

## Troubleshooting que fiz (2026-10-19)

**Sintoma:** perdi o MFA do root, abri um chamado e o projeto ficou parado. Só que o número de conta do chamado não batia com o de outros e-mails da AWS.

| Hipótese | Comando ou evidência | O que mostrou |
|---|---|---|
| Era tudo uma conta só | E-mail automático de recuperação: *"You requested access to AWS account …"* | O número era outro. O chamado tinha sido aberto com o ID errado |
| A conta de estudos estava travada pelo mesmo motivo | `aws account get-contact-information` (com o readonly-user) | O telefone principal dela era o meu número atual, então a recuperação sozinha funcionaria |
| O root da conta de estudos usava o e-mail X | Login em outro e-mail e conferir o **Account ID no canto superior direito** | Era uma terceira conta. Eu tinha **três contas** com e-mails diferentes |
| O root era o e-mail Y | Fatores alternativos: o e-mail de verificação já traz o Account ID | Confirmado. Entrei sem o suporte |

Depois de entrar:

- Havia uma **access key de root ativa, 838 dias sem uso**. Apaguei.
- Cadastrei MFA novo. Removi o antigo.

**Lições:**

- Antes de qualquer passo no console, confirme o Account ID no canto superior direito.
- O e-mail de verificação da AWS é uma boa prova de qual conta está em jogo.
- Guarde o QR code ou a chave secreta do MFA em um gerenciador de senhas.
- Mantenha o telefone principal da conta sempre atualizado.
- Liste as suas contas AWS e qual e-mail é root de cada uma. O Gmail entrega `nome+1@gmail.com` na mesma caixa que `nome@gmail.com`, e isso ajuda a esquecer que é outra conta.
