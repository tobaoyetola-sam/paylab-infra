# PayLab on AWS with Terraform

One `terraform apply` creates the whole PayLab stack: network, database, IAM, ECR, ECS (5 Fargate services),
service discovery, load balancer + HTTPS + DNS, and the 5 CI/CD pipelines. One `terraform destroy` removes it.
It builds exactly what the numbered bash scripts in `paylab-infra/` build, with the same names.

| Bash script | Terraform file |
|---|---|
| `00-dns-cert.sh` (zone, certificate) | not managed: looked up with `data` sources in `alb.tf` (persistent) |
| `01-network.sh` | `network.tf` |
| `02-database.sh` | `database.tf` |
| `03-iam.sh` | `iam.tf` |
| `04-ecr.sh` | `ecr.tf` |
| `05-ecs.sh` | `ecs.tf` (cluster, logs, Cloud Map) + `alb.tf` (ALB, listeners, rules, DNS) |
| `06-bootstrap-images.sh` | not needed: the pipelines build the first images |
| `07-services.sh` | `ecs.tf` (task definitions, services) |
| `08-pipelines.sh` | `cicd.tf` |
| `99-teardown.sh` | `terraform destroy` |

The five services are one map in `locals.tf` (port, health path, CPU/memory, env vars, needs the DB?, which target group,
Cloud Map yes/no). Most resources use `for_each` over that map, so adding a service is one new map entry.

## What stays outside Terraform (persistent, never destroyed)

| Thing | How Terraform uses it |
|---|---|
| Public hosted zone `lab.aricxpoint.co` (delegated from Cloudflare) | `data "aws_route53_zone"`. Only the two alias A records `pay.` and `api.` are managed. |
| ACM certificate for `pay.lab.aricxpoint.co` + `api.lab.aricxpoint.co` (ISSUED) and its validation CNAMEs | `data "aws_acm_certificate"` (domain `pay.lab.aricxpoint.co`, status ISSUED, most recent) |
| GitHub connection (CodeConnections, status Available) | `connection_arn` in `terraform.tfvars` |
| ECS service-linked role `AWSServiceRoleForECS` | Not managed (it already exists and survives teardown). In a brand-new account set `create_ecs_service_linked_role = true`. |

## Prerequisites

1. Terraform >= 1.6 (tested with 1.13.3) and AWS CLI v2.
2. Credentials for the **lab account** in your shell:
   ```bash
   export AWS_PROFILE=default        # or your SSO profile; run `aws sso login` first if needed
   aws sts get-caller-identity       # must show your lab account id
   ```
   `allowed_account_ids` in the provider makes Terraform refuse to run against any other account.
   Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your account id, connection ARN and GitHub user
   (`terraform.tfvars` is git-ignored).
3. The zone, the ISSUED certificate and the Available connection above exist (they do).
4. The five GitHub repos `tobaoyetola-sam/paylab-<service>` exist with a `main` branch containing `buildspec.yml`.
5. **Nothing from the bash scripts is still running.** Same names would clash (`alb-sg`, `paylab-db`, `ecsTaskExecutionRole`,
   `paylab/<svc>` repos, pipelines, ...). Run `../99-teardown.sh` first (it keeps the zone, the certificate and the connection),
   or `terraform import` each resource.

## Apply

```bash
cd paylab-infra/terraform
terraform init
terraform apply          # review the plan, type "yes"
```

### What happens, and how long it takes

1. **`terraform apply`: ~12-15 min.** RDS takes most of that. Everything else takes a minute or two.
2. ECR starts **empty**. The task definitions point at `paylab/<service>:latest` (variable `bootstrap_image_tag`),
   so the ECS tasks **fail to pull at first**. That's expected.
3. Each new pipeline starts its **first run automatically**: GitHub source -> CodeBuild pushes `:<sha>` and `:latest`
   -> ECS deploy. **~5-8 min.** The services then start and become healthy, and the site is live.
4. After that, every `git push` to `main` of a service repo builds and deploys it. Terraform ignores the task definition
   revision and desired count on the ECS services (`lifecycle.ignore_changes`), so it never fights the pipelines.

Total from `apply` to working site: **about 20-25 minutes**.

## Verify

```bash
terraform output                                   # URLs and helper commands
eval "$(terraform output -raw watch_pipelines_command)"   # every stage should reach Succeeded
eval "$(terraform output -raw watch_services_command)"    # runningCount 1 for all five
curl -s https://api.lab.aricxpoint.co/health      # {"status":"ok","service":"api-gateway"}
curl -s https://pay.lab.aricxpoint.co/health      # ok
open https://pay.lab.aricxpoint.co
```

If a pipeline's first run failed (for example, IAM permissions still propagating a few seconds after creation), just re-run it:

```bash
aws codepipeline start-pipeline-execution --name paylab-wallet-svc-pipeline
```

Look inside the database with the one-off psql task (prints wallets and the latest payments to the logs):

```bash
eval "$(terraform output -raw psql_run_task_command)"
```

## Destroy

```bash
terraform destroy        # type "yes"; ~10 min (RDS deletion dominates)
```

It removes everything Terraform created: ECR repos with their images (`force_delete`), the artifact bucket with its
contents (`force_destroy`), Cloud Map services with leftover instances (`force_destroy`), RDS without a final snapshot,
the SSM parameters, log groups, IAM roles, ALB, the two DNS records and the security groups (after the services, ALB
and RDS that use them). The zone, the certificate, its validation records and the GitHub connection are untouched.

## State

State is **local** (`terraform.tfstate` in this folder) and must **stay on this laptop**. Without it Terraform can't
update or destroy the stack (you would have to clean up with `../99-teardown.sh`). It also contains the generated DB
password, so don't commit or share it (`.gitignore` excludes it). `.terraform.lock.hcl` pins the provider versions
(aws 6.x, random 3.x) and should be committed.
