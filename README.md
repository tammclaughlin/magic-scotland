# Magic Clubs of Scotland — AWS learning project

A small Flask website (clubs, contacts and meeting times, events, contact form)
with **fictional data**, deployed to a **private test** AWS setup two ways:

1. **EC2**: Ubuntu 24.04 on a `t4g.medium` (ARM / Graviton), configured by **Ansible over SSH**
2. **Containers**: the same app as an ARM Docker image in **ECR**, run on **ECS Fargate**.
   An **ALB** goes in front as the final step, once everything else works

There are two environments, **dev** and **prod**, built by **Terraform**. **GitHub Actions**
reaches AWS through OIDC, so no AWS keys are stored in GitHub. Images are built once and promoted
from dev to prod. There's no domain: the site runs on the addresses AWS gives it, over HTTP.

```
app/              Flask app, YAML data, tests, Dockerfile
infra/bootstrap/  once per account: state bucket, GitHub OIDC role, SES identity, budget
infra/modules/    network, shared, ec2_site, ecs_site, stack (= one whole environment)
infra/envs/       dev/ and prod/: each calls modules/stack with its own state file
ansible/          playbook, roles, inventory/dev + inventory/prod
scripts/          preflight.sh (read-only account check), ecs-deploy.sh
.github/          CI, infra plan/apply, EC2 + ECS deploys, destroy
Makefile          everything you run locally, using your AWS profiles
```

---

## 0. What you need on your laptop

`terraform` (1.10+), `aws` CLI v2, `ansible-core` + `boto3`, `docker` with buildx, `jq`, `make`.

AWS profiles in `~/.aws/config`. The Makefile uses:

| Profile | Used for |
| --- | --- |
| `claude-ro` | `preflight`, `init`, `plan`, `outputs`, `inventory`, Ansible (it only looks up the server) |
| `claude-rw` | `apply`, `destroy`, `push-image`, `promote`, `deploy-ecs` |
| `tam-admin` | `bootstrap` (creates IAM and a budget, which `claude-rw` can't) |

Different names? Use `make plan RO=my-ro-profile RW=my-rw-profile`, or edit the top of the Makefile.

> `make plan` runs with `-lock=false` so the read-only profile doesn't need to write a lock
> file. If `claude-ro` can't decrypt SecureString parameters, run plan with `RO=claude-rw`.

---

## 1. Placeholders still to fill in

```bash
grep -rn CHANGE_ME --exclude-dir=.git .
```

| File | What to set |
| --- | --- |
| `infra/bootstrap/terraform.tfvars` | state bucket name, GitHub owner + repo |
| `infra/envs/dev/terraform.tfvars`, `infra/envs/prod/terraform.tfvars` | SSH public key, your IP |
| `ansible/group_vars/all.yml` | `admin_user` (your login name on the servers) |

Your email (tam.mclaughlin@gmail.com) is already filled in. The `terraform.tfvars` files are
git-ignored, so your email and IP never reach the repo. The playbook refuses to run while
`admin_user` is still a placeholder.

---

## 2. Run the app locally

```bash
make venv && make test
make run           # http://127.0.0.1:5000
make docker-run    # http://localhost:8000
```

Locally, contact-form messages go to `app/instance/submissions.jsonl` and no email is sent.

---

## 3. Check the account, then bootstrap (once)

The account already has some resources in it, so check for clashes first:

```bash
make keys                                          # ~/.ssh/magic-scotland (admin) + magic-scotland-ci
STATE_BUCKET=magic-scotland-tfstate-<account id> make preflight
```

`preflight` is read-only. It reports:
- **Clashes**: an existing GitHub OIDC provider (only one is allowed per account), an SES identity
  for your email, or IAM role, ECR, SSM, DynamoDB or key-pair names already taken.
  It also tells you which `create_* = false` switch to set.
- **Quota headroom**: the VPC (default 5) and Elastic IP (default 5) limits. dev + prod need 2 of each.
- **What's already running and costing money**: EC2, NAT gateways, load balancers, unattached
  Elastic IPs, RDS, EKS, ECS. Also this month's spend so far. The $20 budget covers the **whole account**.

Then:

```bash
make bootstrap     # tam-admin; note the outputs
```

- Click the **SES verification email** AWS sends to your Gmail.
- Back up `infra/bootstrap/terraform.tfstate`. It's git-ignored and it's the only copy.

---

## 4. Build dev (then prod)

```bash
make init  ENV=dev
make plan  ENV=dev
make apply ENV=dev
make outputs ENV=dev
```

Confirm the **SNS alarm subscription** email. Repeat everything with `ENV=prod` when dev works.

`enable_ecs = false` to start with. Turn it on once an image tagged `latest` is in that
environment's ECR (step 6).

---

## 5. EC2 path: Ansible over SSH

```bash
make ansible-deps
make inventory        ENV=dev    # lists the server
make deploy-ec2-check ENV=dev    # dry run
make deploy-ec2       ENV=dev
```

The first run logs in as `ubuntu` with your admin key. It then creates your `admin_user`,
installs your key plus the CI key, hardens SSH and deploys the app. Check that this works:
`make ssh ENV=dev ADMIN_USER=<you>`. Then set `keep_bootstrap_user_login: false` in
`ansible/group_vars/all.yml` and run again to close the `ubuntu` login.

Open the site at `make outputs ENV=dev` → `site_url_ec2`. A second run of the playbook should
report no changes.

To run the same container image as ECS on the EC2 box: `make deploy-ec2-docker ENV=dev`.

---

## 6. Container path: ECR + ECS Fargate

```bash
make push-image ENV=dev        # builds linux/arm64, pushes :<git sha> and :latest
# set enable_ecs = true in infra/envs/dev/terraform.tfvars
make apply ENV=dev
make ecs-url ENV=dev           # http://<task public ip>:8000
make deploy-ecs ENV=dev        # later deploys of a new tag

make promote                   # same image dev -> prod (TAG=<sha> for a specific one)
make deploy-ecs ENV=prod
```

There's no load balancer yet. Each task gets a public IP and port 8000 is open to
`web_allowed_cidrs`. **The IP changes on every deploy**, so run `make ecs-url` again after each
one. Fixing that is what the ALB is for (step 10).

---

## 7. GitHub setup

1. Create the repo and push this code.
2. **Settings → Environments**: create `dev` and `prod`. On `prod`, add yourself as a **required
   reviewer**. Every prod apply or deploy then waits for your click.
3. **Settings → Branches**: protect `main` (pull request + CI must pass).
4. **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Repo variable | `AWS_ROLE_ARN` | bootstrap output `github_actions_role_arn` |
| Repo variable | `TF_STATE_BUCKET` | bootstrap output `state_bucket` |
| Repo variable | `TF_VAR_SSH_PUBLIC_KEY` | contents of `~/.ssh/magic-scotland.pub` |
| Repo variable | `TF_VAR_SSH_ALLOWED_CIDRS` | `["<your ip>/32"]` |
| Repo variable | `TF_VAR_WEB_ALLOWED_CIDRS` | `["0.0.0.0/0"]` or `["<your ip>/32"]` |
| Repo variable | `TF_VAR_NOTIFY_EMAIL`, `TF_VAR_ALARM_EMAIL` | your email |
| Repo variable | `ADMIN_USER` | same as `admin_user` in Ansible |
| Repo variable | `ADMIN_PUBLIC_KEY` | contents of `~/.ssh/magic-scotland.pub` |
| Repo variable | `CI_PUBLIC_KEY` | contents of `~/.ssh/magic-scotland-ci.pub` |
| Repo **secret** | `SSH_PRIVATE_KEY` | contents of `~/.ssh/magic-scotland-ci` (private CI key) |
| Env variable (dev, prod) | `ENABLE_EC2`, `ENABLE_ECS`, `ENABLE_ALB` | `true` / `false` (ALB last) |

Run `make deploy-ec2` from your laptop **once** before the first CI deploy, so the CI key is
installed on the server.

---

## 8. The pipelines

| Workflow | When | What |
| --- | --- | --- |
| `ci.yml` | every push / PR | black, flake8, pytest, ARM image build + Trivy scan, terraform fmt/validate/tflint (both envs), ansible-lint |
| `infra.yml` | PR touching `infra/` | `terraform plan` for dev and prod, posted on the PR |
| `infra.yml` | merge to `main` | apply **dev**, then **prod** after approval |
| `deploy-ec2.yml` | merge touching `app/` or `ansible/` | Ansible over SSH to **dev**, then **prod** after approval |
| `deploy-ecs.yml` | merge touching `app/` | build the ARM image once, push it to dev ECR, scan it, deploy **dev**, promote the same image to **prod** and deploy after approval |
| `destroy.yml` | manual | `terraform destroy` one environment (type `destroy-dev` / `destroy-prod`) |

**How CI uses plain SSH:** port 22 is normally open only to your IP. For a deploy, the
workflow finds the server's security group and adds a rule for the **runner's own IP (/32)**.
It runs Ansible with the CI key, then **always removes the rule**, even if the deploy fails.

Environments with nothing running (no EC2 instance, no ECS service yet) are skipped, not failed.

**Private site?** If `web_allowed_cidrs` is your IP only, the "smoke test from outside" steps
can't reach the site from GitHub. They're marked as allowed to fail, and the real check runs
on the server itself (the playbook's final health check, or ECS waiting for healthy targets).

---

## 9. Keep costs down

- Run one path at a time with `enable_ec2` / `enable_ecs`, and keep prod off until you need it.
- Leave `enable_alb` off until the final step. The ALB is the biggest fixed cost (~$20/month per env).
- Destroy at the end of a session: `make destroy ENV=dev` (or the `destroy.yml` workflow).
- The bootstrap stack costs pennies, so leave it in place.
- The budget emails you at 80% (forecast) and 100% (actual) of $20 for the **whole account**.

Rough on-demand cost per environment, if left running 24/7 with both paths on, is about
$45–50/month without the ALB, and $65–75 with it. For both environments, double that. Check in the
[AWS Pricing Calculator](https://calculator.aws/).

---

## 10. Final step: add the load balancer

Do this only once the EC2 path and the container path both work in dev.

```bash
# infra/envs/dev/terraform.tfvars
enable_alb = true

make plan  ENV=dev             # adds: ALB, target group, listener, ALB security group, 2 alarms;
                               # changes: task security group (8000 from the ALB only), ECS service
make apply ENV=dev
make ecs-url ENV=dev           # now prints http://<alb dns name> - stable across deploys
```

What changes:
- **One stable address** instead of a task IP that moves on every deploy.
- **Health checks** on `/healthz`: unhealthy tasks are replaced, and rolling deploys switch over
  with no downtime.
- Tasks **no longer accept traffic directly**: port 8000 is open only to the ALB.
- **Two alarms** start working: 5xx errors, and no healthy tasks.
- **Cost**: about $20/month per environment, plus a public IPv4 charge per AZ.

Then do the same for prod, and set `ENABLE_ALB=true` in the GitHub `dev` / `prod` environments so
CI applies match.
To undo: `enable_alb = false` and apply.

---

## Known learning shortcuts (fix later)

- The GitHub Actions role has `AdministratorAccess` (trust is limited to this repo).
- Plain HTTP only. No domain means no Let's Encrypt or ACM certificate. HTTPS is wired in and
  switches on if you ever set `domain_name`.
- Until the ALB step, the Fargate task is reached directly on its public IP, port 8000.
- Fargate tasks use public IPs instead of a NAT gateway, to save ~$35/month per environment.
- `host_key_checking` is off in Ansible because Elastic IPs get reused between rebuilds.

Before your first commit, run `make fmt`. These files were written where Terraform couldn't run,
so some spacing may need tidying; CI checks it.
