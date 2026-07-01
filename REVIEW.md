# REVIEW

## Summary

I reviewed this codebase the way I would a teammate's PR before it goes anywhere near production.

The most urgent problems are around secrets: a `.env` file with real-looking credentials was committed to the repo, the same password is hardcoded in three places (app, Dockerfile, Terraform variable), and the ECS task is running with full AWS `AdministratorAccess`. On top of that, every port is open to the internet on a Fargate task that has no SSH daemon, and there's no visibility into whether the service is actually healthy.


The changes are split into two pull requests by priority:

- `fix/security-hygiene`,  committed `.env`, hardcoded secrets, wide-open security group, IAM `AdministratorAccess`
- `fix/hardening-and-observability`,  Dockerfile hardening, health check, CloudWatch logging, secret scanning, immutable image tags, remove continue-on-error on tests

Secret values are intentionally expected to be created out-of-band (CLI, Console, CI/CD) to avoid storing sensitive values in Terraform state.

## Findings

| # | Issue | Why it matters | Fix | Priority | Fixed in |
|---|-------|-----------------|-----|----------|----------|
| 1 | `.env` committed to the repo with `DB_PASSWORD` and `API_TOKEN` | Real secrets in git history are compromised the moment they're pushed, even if removed later,  rotation is mandatory | Deleted the file, added `.env*`/`*.tfstate*`/`.terraform/` to `.gitignore`. **Action for the team: rotate both values**, they may already be in git history/forks | Blocker | `fix/security-hygiene` |
| 2 | `DB_PASSWORD` hardcoded in `app.py` default, `Dockerfile` `ENV`, and `variables.tf` default; passed as plaintext `environment` value in the ECS task definition | Plaintext secrets end up in Docker image layers, Terraform state, the rendered ECS task definition, and CI logs | Removed all hardcoded defaults. `app.py` requires `DB_PASSWORD` from env with no fallback. Infra creates an `aws_secretsmanager_secret` and injects it via ECS `secrets` (resolved at task start, never stored as plaintext) | Blocker | `fix/security-hygiene` |
| 3 | Security group: ingress `0–65535/tcp` from `0.0.0.0/0`, plus `22/tcp` from `0.0.0.0/0` | Entire port range open to the internet on a public-IP Fargate task; port 22 is meaningless here (no SSH-able host) and just adds attack surface | Split into ALB security group (80/tcp from internet only) and app security group (8080/tcp from the ALB SG only). Removed the SSH rule entirely | Blocker | `fix/security-hygiene` |
| 4 | ECS task role *and* execution role were the same role, with `AdministratorAccess` attached | A compromised container would have full control of the AWS account | Split into a proper execution role (`AmazonECSTaskExecutionRolePolicy` + scoped `secretsmanager:GetSecretValue` on just this secret) and a task role with no permissions until actually needed | Should-fix | `fix/security-hygiene` |
| 5 | No ECR authentication step before `docker push` | AWS credentials are set as env vars but never used to authenticate the Docker daemon against ECR. docker push will fail on any clean runner with an auth error | Added aws ecr  `configure-aws-credentials` and `amazon-ecr-login` step before build/push | Blocker | `fix/hardening-and-observability` |
| 6 | `FROM python:latest`, runs as root, `COPY . .` with no `.dockerignore` | `latest` isn't reproducible and pulls a larger base image; running as root is unnecessary privilege; `COPY . .` risks copying `.env`/`.git`/state files into the image | Pinned to `python:3.12-slim`, added a non-root `app`, reordered `COPY` for layer caching, added `.dockerignore` | Should-fix | `fix/hardening-and-observability` |
| 7 | ALB target group had no health check configured (defaults to `/`) | App already exposes a dedicated `/health` endpoint; using `/` couples liveness to business-logic routes | Added `health_check { path = "/health" ... }` | Should-fix | `fix/hardening-and-observability` |
| 8 | No log configuration on the ECS task | No way to see application logs without exec-ing into a running task | Added `awslogs` `logConfiguration` + `aws_cloudwatch_log_group` | Should-fix | `fix/hardening-and-observability` |
| 9 | Pipeline always builds/deploys `:latest`; no immutable tag | Can't tell which commit is running, and "rollback" means guessing at a previous `:latest` that may no longer exist | Tag and push images with `${{ github.sha }}` (keep `:latest` as a convenience alias), pass `-var="image_tag=..."` to `terraform apply` | Should-fix | `fix/hardening-and-observability` |
| 10 | `pytest` step had `continue-on-error: true` | A failing test suite did not block deploy,  defeats the purpose of having tests | Removed `continue-on-error` | Should-fix | `fix/hardening-and-observability` |
| 11 | `app.run(..., debug=True)` | Enables Flask debug mode, which exposes an interactive debugger that can execute arbitrary code if exposed in production. | Default to `debug=False`, controllable via `FLASK_DEBUG` env var for local dev only | Should-fix | `fix/hardening-and-observability` |
| 12 | `terraform apply -auto-approve` runs directly on every push to `main`, no plan review/approval gate; AWS creds are long-lived IAM keys in GH Actions secrets | A bad merge applies infra changes with no human in the loop; long-lived keys are a standing credential risk vs. short-lived OIDC tokens | **Documented, not fixed**,  would add a required-review environment before apply, and switch to GitHub OIDC → AWS IAM role assumption | Should-fix | Not fixed |
| 13 | No Terraform remote state/locking | State lives wherever `terraform init` runs (e.g. an ephemeral GH Actions runner),  gets lost between runs, no lock means concurrent applies can corrupt state | **Documented, not fixed**,  would add an S3 backend | Should-fix | Not fixed |
| 14 | `desired_count = 1`, no autoscaling | Single task with no redundancy; a bad task swap or AZ blip causes downtime even though subnets span 2 AZs | **Documented, not fixed**,  would bump `desired_count` to 2 and add CPU-based autoscaling | Nice-to-have | Not fixed |
| 15 | ALB listener is HTTP-only, no TLS | Traffic travels in plaintext | **Documented, not fixed**,  needs an ACM cert + 443 listener + 80→443 redirect; needs a real domain, out of scope for a "no AWS account, don't deploy" exercise | Nice-to-have | Not fixed |


## Monitoring 

I would monitor ALB `UnHealthyHostCount`, `HTTPCode_Target_5XX_Count`, and the ECS service's running task count using CloudWatch alarms.

Deployments now use immutable `${{ github.sha }}` image tags, allowing rollback by redeploying a previous image tag or ECS task definition revision.

## Verification


```bash
cd infra
terraform fmt -check
terraform init && terraform validate

```
```bash
docker build -t demo-api .
pytest app/
```


## What I'd do with more time

**These are production-context observations,  I'm aware the current structure is intentional for an assessment of this scope, not a real production system.**

* **Infrastructure and application lifecycle coupling** 
Infrastructure provisioning and application deployment are currently handled within the same Terraform workflow, since ECS service configuration and image versioning are managed together in a single apply cycle.

* **Terraform state management and governance**
Add an S3 backend with state locking to provide a single source of truth for Terraform state. Introduce a `terraform plan` step on pull requests and require manual approval before `terraform apply` on the main branch to improve change visibility and reduce risk of unintended infrastructure changes.

* **CI/CD security improvements**
Secret scanning (Gitleaks) was added because it provides immediate value with minimal complexity and helps prevent accidental credential leakage. Additional improvements such as dependency scanning, container scanning, SBOM generation, image signing (Cosign), and policy enforcement would be natural next steps, but are out of scope for this timebox.

* **CI/CD maintainability**
Standardizing deployments using reusable GitHub Actions workflows would reduce duplication, improve consistency across services, and simplify long-term maintenance.

* **Production readiness improvements**
Enable HTTPS termination using ACM (443 listener with HTTP → HTTPS redirect), increase ECS service desired_count to at least 2 for basic high availability, and configure ECS Service Auto Scaling based on CPU and/or memory utilization.

* **Resource tagging**
Apply a consistent tagging strategy (for example Name, Environment, Application, Owner, and CostCenter) across AWS resources to improve cost allocation, operational visibility, governance, and resource management.