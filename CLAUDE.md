# magic-scotland: AWS learning project

Tam's short-term project to learn AWS CI/CD, containers and Terraform. It's a small
Flask site about Scottish magic clubs, with **fictional data**, deployed to a **private
test** AWS setup two ways: EC2 (Ansible) and ECS Fargate. Tam has extensive Linux
sysadmin experience, so skip the basics and be direct.

`README.md` has the step-by-step procedures. `make help` lists every command.

## Ground rules for Claude

- **Tam deploys, not Claude.** Don't run anything that changes AWS or the servers. Give
  Tam the exact commands to run instead. That includes `make bootstrap / apply /
  destroy / push-image / promote / deploy-ecs / deploy-ec2*`, any `terraform
  apply|destroy|import|state`, `ansible-playbook` without `--check`, and any
  `aws ... create|put|delete|update|authorize|revoke|run`.
- **Read-only AWS is fine**, and only with the `claude-ro` profile: `AWS_PROFILE=claude-ro`,
  e.g. `make preflight`, `make plan`, `make outputs`, `make inventory`, `make ecs-url`,
  `aws ... describe|list|get`. Never use `claude-rw`. If the session has expired, ask
  Tam to run `aws login --profile claude-ro`.
- **Never commit or print secrets.** `terraform.tfvars` files (they hold Tam's email and IP),
  `*.tfstate`, and the private keys `~/.ssh/magic-scotland*` stay out of Git.
  Check `git status` before any commit.
- Before committing changes: `make fmt` and `make test`. Commit to a branch and open a PR
  rather than pushing straight to `main` (merging to `main` triggers deploys).

## Decisions (agreed 13 Oct 2026)

| Topic | Decision |
| --- | --- |
| Region | eu-west-2 (London) |
| App | Python 3.12 + Flask + Gunicorn behind Nginx; data in `app/data/*.yaml` (fictional: 6 clubs, 6 events) |
| Contact form | DynamoDB + SES email to/from tam.mclaughlin@gmail.com; honeypot, rate limit, CSRF |
| Audience | Never public, test only. `web_allowed_cidrs` open by default; locking it to Tam's IP is still an open question |
| Domain | None. AWS's own addresses, HTTP only; HTTPS code exists but stays off (`domain_name = ""`) |
| EC2 | Ubuntu 24.04, **t4g.medium (ARM)**, EIP, IMDSv2, encrypted gp3 |
| Images | Built for **linux/arm64** only |
| Containers | ECR + **ECS Fargate**, no EKS. Tasks reached on public IP:8000 (`make ecs-url`) |
| Load balancer | **Final step only** (`enable_alb = true`), once EC2 and ECS both work |
| Environments | **dev + prod**, separate state files; image built once, promoted dev → prod; prod needs approval in GitHub |
| CI → AWS | GitHub OIDC role (AdministratorAccess for now; trust limited to the repo) |
| CI → server | **Plain SSH** with a separate CI key; port 22 opened to the runner's /32 during a deploy, always closed after |
| AWS account | **Existing**, with a few resources: `make preflight` before bootstrap |
| Local AWS | `~/.aws/config` profiles `claude-ro` (read/plan) and `claude-rw` (changes, Tam only) |
| Budget | $20/month alert, account-wide (in bootstrap) |
| Git | Local repo `/home/tam/gitrepos/magic-scotland`, GitHub `tammclaughlin/magic-scotland`, branch `main` |

## Layout

```
app/              Flask app, tests, Dockerfile (multi-stage, non-root, arm64)
infra/bootstrap/  once per account, local state: state bucket, OIDC role, SES identity, budget
infra/modules/    network, shared, ec2_site, ecs_site, stack (= one whole environment)
infra/envs/       dev/, prod/: call modules/stack; bucket passed at init (-backend-config)
ansible/          site.yml, roles, inventory/{dev,prod} (aws_ec2 plugin by tags)
scripts/          preflight.sh (read-only account check), ecs-deploy.sh, ecs-url.sh
.github/          ci, infra (plan PR / apply dev→prod), deploy-ec2, deploy-ecs, destroy
Makefile          ENV=dev|prod, RO=claude-ro, RW=claude-rw
```

Resource names follow `magic-scotland-<env>`, with tags `Project=magic-scotland`, `Env`, `Role=web`.

## Status and next steps

Code was written in a cloud session where Terraform, Ansible and pytest couldn't run, so
**none of it has been executed for real yet**. Expect to fix small issues as each step runs.

- [x] Repo pushed to GitHub (`main`)
- [ ] 1. Check tools: terraform ≥ 1.10, aws CLI v2, ansible-core + boto3, docker buildx, jq
- [ ] 2. `make venv && make test && make run`; `make fmt`; check the first CI run in GitHub Actions
      (Infrastructure is expected to fail until GitHub variables exist)
- [ ] 3. Fill in placeholders (`grep -rn CHANGE_ME .`):
      - `infra/bootstrap/terraform.tfvars`: `github_repo = "magic-scotland"`, `state_bucket_name`
      - `infra/envs/{dev,prod}/terraform.tfvars`: `ssh_public_key`, `ssh_allowed_cidrs`
      - `ansible/group_vars/all.yml`: `admin_user` (tam)
      - `make keys` creates `~/.ssh/magic-scotland` (admin) and `~/.ssh/magic-scotland-ci`
- [ ] 4. `aws login --profile claude-ro`, then `STATE_BUCKET=magic-scotland-tfstate-<acct> make preflight`.
      Review clashes (likely an existing GitHub OIDC provider → `create_github_oidc_provider = false`),
      quotas, and what's already running
- [ ] 5. Tam: `make bootstrap`, then click the SES verification email
- [ ] 6. GitHub settings: dev/prod environments (prod reviewer), branch protection, variables
      and the `SSH_PRIVATE_KEY` secret (README section 7)
- [ ] 7. dev: `make init plan` (Claude can run these with claude-ro) → Tam: `make apply`
- [ ] 8. Tam: `make deploy-ec2 ENV=dev` (first run as ubuntu), check the site, then
      `keep_bootstrap_user_login: false`
- [ ] 9. Containers: Tam: `make push-image`, `enable_ecs = true`, `make apply`; `make ecs-url`
- [ ] 10. prod: same as 7–9 with `ENV=prod`; `make promote`
- [ ] 11. Final step: `enable_alb = true` in dev, then prod
- [ ] Later: scope down the GitHub role; decide on locking `web_allowed_cidrs` to Tam's IP

Update this checklist as steps are completed.

## Known risks to watch

- Terraform files weren't `terraform validate`d when written. Run `make fmt` and fix whatever
  `terraform validate` reports.
- `make plan` uses `-lock=false` for the read-only profile. If `claude-ro` can't decrypt
  SecureString parameters, the plan may need `RO=claude-rw`, so ask Tam.
- SES sends from a Gmail address, so the first notifications may land in spam.
- Elastic IP and VPC quotas in an existing account: dev + prod need 2 of each.
