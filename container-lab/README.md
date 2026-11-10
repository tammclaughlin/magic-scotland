# Container lab: the site on Fargate, nginx + Gunicorn in containers

A small, self-contained way to learn the container workflow: build the images, run them
locally, push them to a registry, run them on ECS Fargate. It does what the EC2 path
does (Nginx in front of Gunicorn), so you can compare the two step by step.

It doesn't touch anything that exists: not the main `Makefile`, not `infra/`, not the
dev/prod stacks. It **reads** from the dev stack (VPC, subnets, SSM parameters, the app's
IAM policy), so dev must be applied. Everything it creates is named
`magic-scotland-dev-lab*` and goes away with `make down`.

```
container-lab/
  nginx/Dockerfile      the nginx image          (≈ ansible/roles/nginx)
  nginx/default.conf    its config               (≈ roles/nginx/templates/magic.conf.j2)
  compose.yml           both containers locally  (≈ the server, on your laptop)
  terraform/main.tf     ECR, IAM, task, service  (≈ infra/modules/ec2_site, all in one file)
  Makefile              the steps below
```
The app image is the existing `app/Dockerfile`, used as is.

## EC2 + Ansible vs containers

| Step | EC2 + Ansible | Containers on Fargate |
| --- | --- | --- |
| Where it runs | a server you patch and look after | a task: AWS runs the containers, there's no server to log in to |
| Install nginx | `apt: nginx` on the server, every run | `FROM nginx:1.28-alpine`, once, at build time |
| Install the app | pip into a venv on the server | `pip install` in `app/Dockerfile`, at build time |
| Config | `template:` writes the file, handler reloads | `COPY default.conf` into the image. New config = new image |
| Check config | `nginx -t` task | `RUN nginx -t`: a broken config fails the **build** |
| Start, keep running | systemd units, `enabled: true` | the ECS service keeps 1 task running and replaces it if it dies |
| Start order | `After=` / `Requires=` | `dependsOn: web HEALTHY` in the task definition |
| nginx → app | `127.0.0.1:8000` | also `127.0.0.1:8000`: containers in a task share a network namespace |
| Deploy a change | re-run the playbook, it changes the server in place | build a new image, new task definition revision, ECS swaps the task |
| Roll back | re-run with the old version and hope | the previous revision still exists. The circuit breaker rolls back by itself |
| Firewall | security group + ufw: 80 in, 8000 closed | security group: 80 in, 8000 bound to 127.0.0.1 only |
| Permissions | one instance profile | execution role (ECS pulls images, writes logs) + task role (your code) |
| Logs | `journalctl`, `/var/log/nginx` | stdout/stderr → CloudWatch Logs (`make logs`) |
| Get a shell | `ssh` | `aws ecs execute-command` (`make shell`) |
| Address | Elastic IP, stays the same | the task's public IP, **changes every deploy** (an ALB fixes that) |

## Before you start

- `aws login --profile tam` (claude-ro and claude-rw chain from it)
- docker buildx able to build arm64. On an x86 machine, check `docker buildx ls` lists
  `linux/arm64`; if it doesn't: `docker run --privileged --rm tonistiigi/binfmt --install arm64`
- For `make shell` only: the AWS `session-manager-plugin`

All commands run from `container-lab/`. `make help` lists them. Make prints each command
before it runs it; read them, because they're the bit you're learning.

## 1. Build and run locally: `make run`

```bash
docker compose up --build        # what make run does
# http://localhost:8080   (Ctrl-C to stop, docker compose down to clean up)
```
Compose builds two images (`magic-lab-app` from `../app`, `magic-lab-nginx` from `nginx/`)
and runs them the way Fargate will: nginx inside web's network namespace, Gunicorn on
127.0.0.1:8000. Things to try in another terminal:
```bash
docker images | grep magic-lab              # the images and their sizes
docker history magic-lab-nginx              # one layer per Dockerfile instruction
docker compose exec nginx nginx -T          # the config nginx actually loaded
docker compose exec web ps aux              # one process tree per container, PID 1 = gunicorn
curl -I localhost:8080/static/style.css     # Expires and the security headers come from nginx
```

## 2–4. Create the AWS side with no tasks: `make init plan infra`

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -var image_tag=$(git rev-parse --short=12 HEAD)   # claude-ro
terraform -chdir=terraform apply -var image_tag=                                   # claude-rw
```
With an empty `image_tag` the service runs **0 tasks**. That's needed the first time: the
ECR repos have to exist before you can push to them, and a task can't start without its
images. 16 resources: 2 ECR repos (+ lifecycle policies), log group, 2 IAM roles (+
policies), security group (+ rules), task definition, cluster, service. State is local, in `terraform/terraform.tfstate`.

## 5. Build for ARM and push: `make push`

```bash
reg=$(terraform -chdir=terraform output -raw registry)       # <account>.dkr.ecr.eu-west-2.amazonaws.com
aws ecr get-login-password --profile claude-rw | docker login -u AWS --password-stdin $reg
docker buildx build --platform linux/arm64 --push -t $reg/magic-scotland-dev-lab-app:<tag>   ../app
docker buildx build --platform linux/arm64 --push -t $reg/magic-scotland-dev-lab-nginx:<tag> nginx
```
The tag is the commit SHA (with `-dirty` if `app/` or `nginx/` have uncommitted changes),
so every image says where it came from. `--platform linux/arm64` because the task runs on
Graviton (cheaper); on an x86 laptop buildx emulates ARM, so it's slower than step 1.
Look at the result: ECR console → repository → image → scan findings.

## 6. Run it: `make deploy`

```bash
terraform -chdir=terraform apply -var image_tag=<tag>        # claude-rw
```
Terraform registers a new **task definition revision** with the new image tags and
points the service at it. ECS then pulls the images, starts `web`, waits for it to be
healthy, starts `nginx`, and the apply returns once the task is steady (2–3 minutes).
`make url` prints `http://<task public ip>` and checks `/healthz`.

## Changing something

```bash
# edit app/ or nginx/default.conf, then commit (or don't: the tag gets -dirty)
make run              # try it locally first
make push deploy      # new images, new revision, rolling replacement
make logs             # both containers, prefixed web/… and nginx/…
make shell            # sh in the web container; C=nginx make shell for nginx
```

Things worth trying once it works:
- `aws ecs list-task-definitions --family-prefix magic-scotland-dev-lab --profile claude-ro`:
  one revision per deploy. `describe-task-definition` shows what each one ran.
- Break the nginx config (e.g. a typo in a directive) and `make run`: the build stops at
  `RUN nginx -t`, before anything is deployed.
- Break the app's health check, then `make push deploy`: the new task never gets healthy,
  the circuit breaker rolls the service back to the previous revision, and the apply fails.
- Stop the task by hand (`aws ecs stop-task`, claude-rw) and watch the service start a new
  one, with a new IP.

## Stop paying: `make down`

```bash
terraform -chdir=terraform destroy -var image_tag=           # claude-rw
```
Running cost while a task is up: Fargate ARM 0.25 vCPU / 0.5 GB ≈ $0.01/hour, plus
$0.005/hour for the public IPv4, so ≈ $10/month if left running. `make infra` (no tag) scales
to 0 tasks but keeps the repos, roles and cluster, which cost next to nothing.

## Not covered here (the main stack does these)

- A load balancer for a fixed address and zero-downtime deploys: `enable_alb` in `infra/`
- CI building and deploying on merge: `.github/workflows/deploy-ecs.yml`
- dev → prod promotion of the same image: `make promote` in the main Makefile
