# Magic Clubs of Scotland — AWS learning project

A small Flask website (clubs, contacts and meeting details, events, contact form)
deployed two ways on AWS:

1. **EC2** — Ubuntu on a t3.medium, configured by **Ansible**, Nginx in front of Gunicorn
2. **Containers** — the same app as a Docker image in **ECR**, run on **ECS Fargate** behind an ALB

All infrastructure is **Terraform**; CI/CD is **GitHub Actions** using OIDC (no AWS keys in GitHub).

```
app/        Flask app, YAML data, tests, Dockerfile
infra/      Terraform: bootstrap (state + OIDC), modules, envs/dev
ansible/    Playbook and roles for the EC2 host
.github/    CI, infra plan/apply, deploy-ec2, deploy-ecs, destroy
```

---

## 1. Fill in the placeholders

Every value I didn't know is marked `CHANGE_ME`. Find them all with:

```bash
grep -rn CHANGE_ME --exclude-dir=.git .
```

| File | What to set |
| --- | --- |
| `infra/bootstrap/terraform.tfvars` (copy from `.example`) | State bucket name, GitHub owner and repo |
| `infra/envs/dev/backend.tf` | State bucket name (from the bootstrap output) |
| `infra/envs/dev/terraform.tfvars` (copy from `.example`) | SSH public key, your IP, notify/sender/budget emails, domain (optional) |
| `ansible/group_vars/all.yml` | Admin username, SSH key path, domain + Let's Encrypt email (optional) |
| `app/data/clubs.yaml`, `app/data/events.yaml` | Real clubs and events (samples are fictional) |
| `app/magic/templates/privacy.html` | Your privacy notice wording, owner name, retention period |
| `.github/workflows/deploy-ecs.yml` | Only if you choose ARM/Graviton: `linux/arm64` |

Before your first commit run `terraform fmt -recursive infra` (I couldn't run Terraform
where these files were written, so spacing may need tidying; CI checks it).

`terraform.tfvars` files are git-ignored, so your emails and IP stay out of Git.
The playbook refuses to run while key `CHANGE_ME` values are still set.

---

## 2. Run the app locally

```bash
cd app
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
flask --app wsgi run --debug           # http://127.0.0.1:5000
# or as a container:
docker compose up --build              # http://localhost:8000
```

Locally, contact-form messages go to `app/instance/submissions.jsonl` and no email is sent.

---

## 3. Bootstrap AWS (once, from your laptop)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/magic-scotland -C magic-scotland

cd infra/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit it
terraform init && terraform apply
terraform output                               # note state_bucket and github_actions_role_arn
```

Back up `infra/bootstrap/terraform.tfstate` somewhere safe (it is git-ignored).

---

## 4. Build the dev environment

```bash
cd infra/envs/dev
# put the state bucket name in backend.tf
cp terraform.tfvars.example terraform.tfvars   # edit it
terraform init
terraform plan
terraform apply
terraform output
```

Afterwards:

- Click the **SES verification emails** AWS sends to your notify/sender addresses.
- Confirm the **SNS alarm subscription** email.
- If you set `domain_name`, a Route 53 hosted zone for it must already exist.

Start with `enable_ecs = false`. Turn it on after the first image is in ECR (step 7).

---

## 5. Configure the EC2 server with Ansible

```bash
cd ansible
pip install ansible-core boto3 botocore
ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph                      # should list the web server
ansible-playbook site.yml --check --diff       # dry run
ansible-playbook site.yml
```

Then visit `terraform output site_url_ec2`. Run the playbook a second time: it should
report no changes.

Once you can log in as your admin user, set `keep_bootstrap_user_login: false` and run
again to lock out the default `ubuntu` login.

Switch the server to the container image (phase 5):

```bash
ansible-playbook site.yml -e app_mode=docker -e ecr_repository_url=<ecr url> -e app_image_tag=<tag>
```

---

## 6. GitHub setup

1. Create the repo and push this code.
2. **Settings → Environments → New environment `dev`** — add yourself as a required reviewer
   (this is the manual approval before `terraform apply` and deploys).
3. **Settings → Branches** — protect `main`: require a pull request and passing CI.
4. **Settings → Secrets and variables → Actions → Variables** — add:

| Variable | Value / source |
| --- | --- |
| `AWS_ROLE_ARN` | bootstrap output `github_actions_role_arn` |
| `TF_VAR_SSH_PUBLIC_KEY` | contents of `~/.ssh/magic-scotland.pub` |
| `TF_VAR_SSH_ALLOWED_CIDRS` | JSON list, e.g. `["203.0.113.10/32"]` |
| `TF_VAR_NOTIFY_EMAIL`, `TF_VAR_SES_SENDER_EMAIL`, `TF_VAR_BUDGET_EMAIL` | your emails |
| `TF_VAR_DOMAIN_NAME` | your domain, or leave empty |
| `TF_VAR_ENABLE_EC2`, `TF_VAR_ENABLE_ECS` | `true` / `false` |
| `ECR_REPOSITORY_URL` | dev output `ecr_repository_url` |
| `ANSIBLE_SSM_BUCKET` | dev output `ansible_ssm_bucket` |
| `ADMIN_USER`, `ADMIN_PUBLIC_KEY` | same as in `group_vars/all.yml` |
| `EC2_SITE_URL` | dev output `site_url_ec2` |
| `ENABLE_EC2_DEPLOY` | `true` to switch on the EC2 deploy workflow |
| `ECS_CLUSTER`, `ECS_SERVICE`, `ECS_TASK_FAMILY` | dev outputs `ecs_cluster`, `ecs_service`, `ecs_task_family` |
| `ECS_SITE_URL` | dev output `alb_url` |
| `ENABLE_ECS_DEPLOY` | `true` once the ECS service exists |

Note: these are *variables*, not secrets, because none of them is secret.
The SSH **private** key is never stored in GitHub — CI reaches the server through SSM.

---

## 7. The pipelines

| Workflow | When | What |
| --- | --- | --- |
| `ci.yml` | every push / PR | black, flake8, pytest, Docker build + Trivy scan, terraform fmt/validate/tflint, ansible-lint |
| `infra.yml` | PR touching `infra/` | `terraform plan` posted as a PR comment |
| `infra.yml` | merge to `main` | `terraform apply` after approval |
| `deploy-ec2.yml` | merge touching `app/` or `ansible/` | Ansible over SSM, smoke test |
| `deploy-ecs.yml` | merge touching `app/` | build, push `:<sha>` to ECR, scan, new task definition, rolling deploy, smoke test |
| `destroy.yml` | manual, type `destroy-dev` | `terraform destroy` of the dev environment |

**Turning on ECS:** after `deploy-ecs.yml` has pushed at least one image (`:latest`),
set `TF_VAR_ENABLE_ECS=true` (or `enable_ecs = true` locally) and apply. Then set
the `ECS_*` variables and `ENABLE_ECS_DEPLOY=true`.

---

## 8. Keep costs down

- Run one path at a time with `enable_ec2` / `enable_ecs`.
- Destroy at the end of a session: `terraform destroy` in `infra/envs/dev`, or the `destroy.yml` workflow.
- The bootstrap stack (state bucket, OIDC role) costs pennies — leave it.
- The budget alert emails you at 80% (forecast) and 100% (actual) of `monthly_budget_usd`.

Rough on-demand cost if everything is left running 24/7 is about $75–85/month; check
in the [AWS Pricing Calculator](https://calculator.aws/).

---

## Known learning shortcuts (fix later)

- The GitHub Actions role has `AdministratorAccess` (trust is limited to this repo).
  Scope it down once the project settles.
- One environment (`dev`). A `prod` env is a copy of `infra/envs/dev` with its own state key.
- Fargate tasks use public IPs instead of a NAT gateway, to save ~$35/month.
