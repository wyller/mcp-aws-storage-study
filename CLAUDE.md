# AWS storage studies

Study account `004009722521` (alias `wyller-estudos`), default region `us-east-1`. The goal is practice for DevOps interviews and work: real troubleshooting and a sense of cost. Not certification cramming.

## Language

- Code, comments, Terraform, scripts, skills and commit messages are in **English** (switched on 2026-10-21 as a study exercise; tag `pt-br` marks the state before it).
- Talk to the user in **Brazilian Portuguese**. Keep AWS and Terraform terms in English.
- `notas/` stays in Portuguese: those are the user's notes. Translate an existing note only if asked.

## Rules

- **Never create, change or start anything in AWS.** Diagnose (read configs, logs, metrics and policies) and hand over the command or the console path. The user runs it.
- **Never touch human access:** root, `readonly-user` (keys, policies, MFA), budget and billing.
- Reading: use the `aws-api` MCP (read-only) or `aws ... describe/list/get` with the default profile.
- Documentation: use the `aws-knowledge` MCP before answering from memory. Cite the link.
- Deleting: the main path is `terraform destroy`, which the user runs with `aws-lab`. Before that, run `terraform plan -destroy` with the default profile and check what goes away. For what was left out of the state (created in the console, an apply that failed halfway), use the `/aws-cleanup` skill. No ad-hoc `delete-*`.
- After any cleanup, run `scripts/inventory.sh` to confirm nothing billable is left.

## Identities

| Profile | Identity | Can |
|---|---|---|
| `default` | `readonly-user` | read; also has `CustomS3CreateBucket`/`DeleteBucket` (it's human access) |
| `cleanup` | `claude-cleanup-role` | read and delete; 1h session; denies protected identities, `lab-s3-read-role` and billing |
| `lab` | `terraform-lab-role` | create (PowerUser + `lab-*` roles); requires MFA; **only the user uses it**, via `aws-lab` |

## Helping with the studies

- When explaining a service, include **how it bills**: what counts per hour, what counts per GB and what counts even when idle.
- In troubleshooting, show the reasoning: hypothesis → command that confirms it → what the result means.
- The user's notes live in `notas/`. Offer to write there when a lesson worth keeping comes up.

## Files

- `nuke-config.yaml`: what the cleanup protects.
- `policies/`: the `claude-cleanup-role` policies, pasted by the user in the console. Kept byte-for-byte as in AWS (not translated).
- `terraform/iam-compartilhado`: IAM shared between days; never destroyed, kept as is (not translated).
- `scripts/inventory.sh`: quick list of what's billable in every region. Runs on its own when the session opens and closes.
- `SETUP.md`: the user's manual steps in the console.
