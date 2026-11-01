<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/aricxpoint-logo-white.png">
    <img alt="aricxpoint technologies" src=".github/aricxpoint-logo-black.png" width="320">
  </picture>
</p>

# paylab-infra

Shared, one-time AWS setup for **PayLab**, the aricxpoint DevOps class "Payment Web App Deployment".

> **Start here: [`terraform/`](terraform/README.md).** One `terraform apply` builds the whole stack in your own AWS
> account (with or without a domain) and one `terraform destroy` removes it. The architecture diagram is
> [`docs/paylab-architecture.drawio`](docs/paylab-architecture.drawio) (open it at https://app.diagrams.net).
> The numbered `0x-*.sh` scripts below are the original step-by-step version, kept for learning what each AWS CLI
> call does. Don't mix the two in one account.

PayLab is a small payment app made of 5 services. **Each service lives in its own GitHub repo**
and is deployed by its own AWS CodePipeline on every push to `main`:

| Repo | Port | What it does |
|---|---|---|
| `paylab-web` | 3000 | The payment frontend (static HTML/JS on non-root nginx). The ALB's default target. |
| `paylab-api-gateway` | 8080 | Public API. The ALB sends `/api/*` here; it forwards to wallet-svc / payment-svc. |
| `paylab-payment-svc` | 8081 | Owns `payments`. One person pays another (by handle), asks wallet-svc to move the money, sends receipts. Idempotent on `reference`. |
| `paylab-wallet-svc`  | 8082 | Owns `wallets` + `ledger_entries`. Internal `/transfers` debits the payer and credits the payee in one DB transaction; 409 on insufficient funds. |
| `paylab-notify-svc`  | 8083 | Logs JSON receipts, "sent" for the payer and "received" for the payee (stand-in for email/SMS). |
| `paylab-infra` (this repo) | | Network, database, IAM, ECR, ECS cluster, ALB, services, pipelines, teardown. |

## Architecture

```
  Developer
     | git push (main)
     v
+-----------+  CodeConnections  +------------------------------------------------------------+
|  GitHub   |------------------>|  CodePipeline paylab-<svc>-pipeline  (one per service)      |
| paylab-*  |  (push trigger)   |   Source --------> Build ----------------------> Deploy     |
+-----------+                   |   (repo zip)       CodeBuild paylab-<svc>-build  Amazon ECS  |
                                +----------------------|------------------------------|------+
                                    docker build + push|         imagedefinitions.json|
                                                       v                              |
                                        +---------------------------+                 |
                                        | ECR paylab/<svc>          |---image pull--+ |
                                        |   :<commit>  :latest      |               | |
                                        +---------------------------+               v v
  Browser
     | https://pay.lab.aricxpoint.co   https://api.lab.aricxpoint.co
     v
  Route 53 zone lab.aricxpoint.co (delegated from Cloudflare): alias A records -> ALB
     |
+----v----------------------+   ECS cluster "paylab" (Fargate, default VPC public subnets, app-sg)
| paylab-alb (alb-sg)       |  +--------------------------------------------------------------+
|  :80  -> 301 to HTTPS     |  |                                                              |
|  :443 (ACM certificate)   |  |  api-gateway :8080 --> wallet-svc.paylab.internal:8082       |
|   host api.lab... --------+->|        |                    ^ /transfers                     |
|   path /api/*  -----------+->|        +--> payment-svc.paylab.internal:8081                 |
|   (both: paylab-tg)       |  |                    |                                         |
|   default ----------------+->|  web :3000          +--> notify-svc.paylab.internal:8083      |
|   (paylab-web-tg)         |  |                                (receipts -> logs)            |
+---------------------------+  |  Service discovery: Cloud Map namespace "paylab.internal"    |
                               |  (Route 53 private DNS, A records = task IPs, TTL 10s)        |
                               +-------------------------------|------------------------------+
                                                               | 5432
                                  +----------------------------v-------------------+
                                  | RDS PostgreSQL paylab-db (db-sg, private)      |
                                  | password: SSM Parameter Store                  |
                                  |           /paylab/db/password (SecureString)   |
                                  +------------------------------------------------+
     Logs: CloudWatch /ecs/paylab (apps), /aws/codebuild/paylab-<svc>-build (builds)
```

The browser loads the page from `web` at **https://pay.lab.aricxpoint.co** and calls `/api/...` on the **same origin**;
the ALB's HTTPS listener sends `/api/*` (rule 20) to `api-gateway`. The API is also reachable directly at
**https://api.lab.aricxpoint.co** (rule 10, host header). Everything else goes to `web` (default action).
Plain HTTP on :80 is redirected to HTTPS.

Security groups: **alb-sg** (80 and 443 from internet) -> **app-sg** (8080 and 3000 from alb-sg, plus all ports within
app-sg, because tasks call each other directly by private IP) -> **db-sg** (5432 from app-sg). RDS is not publicly accessible.

> **Lab shortcut vs production.** To avoid paying for a NAT gateway, Fargate tasks run in the account's
> **default VPC public subnets** with `assignPublicIp=ENABLED` (needed to pull from ECR and read SSM Parameter Store).
> Inbound traffic is still blocked by the security groups. In production, put tasks and RDS in **private subnets**
> and use a **NAT gateway** or **VPC endpoints** (ECR api/dkr, S3, SSM, CloudWatch Logs).

## Folder layout (on your laptop)

Keep all six repos side by side. Scripts 06 and 07 take the parent folder as an argument:

```
aricxpoint-paylab/
├── paylab-web/           site/ nginx.conf 40-paylab-config.sh Dockerfile buildspec.yml taskdef.json
├── paylab-api-gateway/   server.js Dockerfile buildspec.yml taskdef.json README.md
├── paylab-payment-svc/   ...
├── paylab-wallet-svc/    ...
├── paylab-notify-svc/    ...
└── paylab-infra/         config.sh 01-...08 99-teardown.sh README.md
```

## One-time prerequisite: DNS delegation from Cloudflare

The public hosted zone **`lab.aricxpoint.co`** already exists in Route 53 (these scripts look it up by name and
**never create or delete it**). `aricxpoint.co` itself is on Cloudflare, so Cloudflare must delegate the `lab`
subdomain to Route 53:

1. Get the zone's four name servers:
   ```bash
   aws route53 get-hosted-zone --id "$(aws route53 list-hosted-zones-by-name --dns-name lab.aricxpoint.co \
     --query 'HostedZones[0].Id' --output text)" --query 'DelegationSet.NameServers' --output text
   ```
2. In Cloudflare -> `aricxpoint.co` -> DNS, add **4 NS records**, name `lab`, one per name server,
   proxy status **DNS only** (NS records can't be proxied anyway).
3. Check: `dig NS lab.aricxpoint.co +short` returns the four `awsdns` servers.

Without this, the certificate in step 0 never validates and the URLs don't resolve.

## Before you start

- AWS CLI v2, Docker (running), `git`, `openssl`, and optionally the GitHub CLI `gh`.
- **Don't use the root user.** Enable **IAM Identity Center**, create a user with the `AdministratorAccess`
  permission set (or, for a throwaway account, an IAM admin user). Then:

  ```bash
  aws configure sso --profile aricxpoint-lab     # start URL, SSO region, pick account + role, default region eu-west-1
  aws sso login --profile aricxpoint-lab
  aws sts get-caller-identity --profile aricxpoint-lab
  ```

- **Set these before running any script** (in every new terminal):

  ```bash
  export AWS_PROFILE=aricxpoint-lab          # default if unset
  export AWS_REGION=eu-west-1                # default if unset
  export EXPECTED_ACCOUNT_ID=<lab account id> # recommended safety guard
  # optional overrides (these are the defaults):
  # export DOMAIN_ZONE=lab.aricxpoint.co WEB_HOST=pay.lab.aricxpoint.co API_HOST=api.lab.aricxpoint.co
  ```

  `EXPECTED_ACCOUNT_ID` is optional but **recommended**: every script checks it against
  `aws sts get-caller-identity` and stops immediately, naming both account IDs, if your profile points at a different account.

- **Budget alert** (email at 80% of USD 10/month):

  ```bash
  aws budgets create-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
    --budget '{"BudgetName":"paylab-monthly","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
    --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]}]'
  ```

All scripts are **idempotent**: if one fails halfway (expired login, a timeout), fix the cause and re-run it;
existing resources are detected and skipped.

> **RDS takes ~10 minutes to create** and the certificate a few more. Instructor: run steps 0, 1 and 2 **before class**.

## Order of operations

| # | Command | What it creates |
|---|---|---|
| 0 | `./00-dns-cert.sh` | **Persistent, run once.** ACM certificate for `pay.lab.aricxpoint.co` + `api.lab.aricxpoint.co`, DNS-validated in the existing zone. Teardown keeps it. |
| 1 | `./01-network.sh` | Security groups `alb-sg` (80, 443), `app-sg`, `db-sg` in the default VPC |
| 2 | `./02-database.sh` | SSM Parameter Store `/paylab/db/password` (SecureString, random alphanumeric) + RDS `paylab-db` (PostgreSQL 16, db.t4g.micro, db `paylab`, user `paylab`). Waits ~10 min, then saves the endpoint to `/paylab/db/host`. |
| 3 | `./03-iam.sh` | `ecsTaskExecutionRole` (+ `ssm:GetParameters` on `/paylab/db/password`), `paylabTaskRole`, `codebuild-paylab-role`, `codepipeline-paylab-role` |
| 4 | `./04-ecr.sh` | ECR repos `paylab/api-gateway`, `paylab/payment-svc`, `paylab/wallet-svc`, `paylab/notify-svc`, `paylab/web` |
| 5 | `./05-ecs.sh` | Log group `/ecs/paylab`; cluster `paylab`; Cloud Map private DNS namespace `paylab.internal`; ALB `paylab-alb`; target groups `paylab-tg` (8080) and `paylab-web-tg` (3000), both ip + `/health`; listener :80 (301 to HTTPS) and :443 (default -> `paylab-web-tg`, rule 10 host `api.lab.aricxpoint.co` and rule 20 path `/api/*` -> `paylab-tg`); Route 53 alias records for both hostnames |
| 6 | `./06-bootstrap-images.sh ..` | **One time:** builds and pushes `paylab/<svc>:v1` for all 5 services from your laptop |
| 7 | `./07-services.sh ..` | Registers each repo's `taskdef.json`, creates a Cloud Map service per backend, creates the 5 ECS services, then waits until stable |
| - | Create the GitHub connection (console, below) and push the 5 service repos to GitHub | |
| 8 | `CONNECTION_ARN=... GITHUB_OWNER=... ./08-pipelines.sh` | Artifact bucket, 5 CodeBuild projects, 5 CodePipelines |
| 99 | `./99-teardown.sh` | Deletes everything (asks you to type `paylab`) |

After step 7, open **https://pay.lab.aricxpoint.co**: the PayLab page. The API health check is **https://api.lab.aricxpoint.co/health**. Create `@ada` in one browser window and `@bola` in another
(or use **Switch wallet**), send money, and watch it arrive on the other side within 4 seconds. Or test with curl:

```bash
ALB=https://pay.lab.aricxpoint.co                     # or https://api.lab.aricxpoint.co: same API
curl -s $ALB/health                                   # "ok" from web
curl -s https://api.lab.aricxpoint.co/health          # {"status":"ok","service":"api-gateway"}
curl -sI http://pay.lab.aricxpoint.co | head -1       # 301 -> https
# two people, ₦10,000 demo credit each
curl -s -X POST $ALB/api/wallets -H 'Content-Type: application/json' -d '{"owner":"Ada","handle":"ada"}'
curl -s -X POST $ALB/api/wallets -H 'Content-Type: application/json' -d '{"owner":"Bola","handle":"bola"}'

# Ada pays Bola ₦1,500 -> 201 "success"; Ada 850000 kobo, Bola 1150000 kobo
curl -s -X POST $ALB/api/payments -H 'Content-Type: application/json' \
  -d '{"fromWalletId":1,"toHandle":"bola","amountKobo":150000,"reference":"aws-1001","note":"Lunch"}'
# same reference again -> 200, the same payment, no second charge
curl -s -X POST $ALB/api/payments -H 'Content-Type: application/json' \
  -d '{"fromWalletId":1,"toHandle":"bola","amountKobo":150000,"reference":"aws-1001","note":"Lunch"}'
# Ada tries ₦999,999 -> 402 "failed", reason "insufficient funds", balances unchanged
curl -s -X POST $ALB/api/payments -H 'Content-Type: application/json' \
  -d '{"fromWalletId":1,"toHandle":"bola","amountKobo":99999900,"reference":"aws-1002"}'

curl -s $ALB/api/wallets/by-handle/bola              # balance
curl -s "$ALB/api/payments?walletId=2"                # Bola's history (received +₦1,500)
aws logs tail /ecs/paylab --since 10m --log-stream-name-prefix notify-svc     # receipts
```

### Service discovery (how the services find each other)

ECS **Service Discovery** with Cloud Map: `05-ecs.sh` creates a private DNS namespace **`paylab.internal`**
(a Route 53 private hosted zone attached to the default VPC). `07-services.sh` creates one Cloud Map service per backend
and passes it to `aws ecs create-service --service-registries registryArn=<arn>`:

```text
aws servicediscovery create-service --name wallet-svc --namespace-id <paylab.internal id> \
  --dns-config '{"RoutingPolicy":"MULTIVALUE","DnsRecords":[{"Type":"A","TTL":10}]}' \
  --health-check-custom-config FailureThreshold=1
aws ecs create-service ... --service-registries registryArn=<that service's ARN>
```

When a task starts, ECS registers its private IP as an A record, e.g. `wallet-svc.paylab.internal`, and removes
it when the task stops. The same happens for `payment-svc`, `notify-svc` and `api-gateway`; `web` needs no record.
The task definitions point at these names:

| Service | Env var | Value |
|---|---|---|
| api-gateway | `WALLET_URL` / `PAYMENT_URL` | `http://wallet-svc.paylab.internal:8082` / `http://payment-svc.paylab.internal:8081` |
| payment-svc | `WALLET_URL` / `NOTIFY_URL` | `http://wallet-svc.paylab.internal:8082` / `http://notify-svc.paylab.internal:8083` |
| api-gateway | `CORS_ORIGIN` | `https://pay.lab.aricxpoint.co` (rendered from `<WEB_HOST>`) |

Tasks talk to each other directly by private IP, which is why app-sg allows all traffic from itself.
(The code's defaults, `http://wallet-svc:8082` etc., are for local Docker.)

### The database password

`02-database.sh` stores the password in **SSM Parameter Store** as `/paylab/db/password` (SecureString, AWS-managed
key `alias/aws/ssm`). The payment-svc and wallet-svc task definitions inject it as `DB_PASSWORD`:

```json
"secrets": [{ "name": "DB_PASSWORD", "valueFrom": "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:parameter/paylab/db/password" }]
```

ECS reads it at task start with the **execution role** (`ssm:GetParameters` + `kms:Decrypt` via SSM). The value never
appears in the task definition or the image. Re-running 02 re-uses the stored password, so it never drifts from RDS.

## The GitHub connection (console, one time)

CodePipeline reads GitHub through an **AWS CodeConnections** connection. Creating it needs a browser
handshake with GitHub, so it **can't be fully done from the CLI**:

1. AWS console -> **Developer Tools** -> **Settings** -> **Connections** -> **Create connection**.
2. Provider **GitHub**, name `paylab-github`, then **Connect to GitHub**.
3. GitHub asks you to authorise "AWS Connector for GitHub". Then click **Install a new app**, choose your
   user/org, and give it access to the five `paylab-*` service repos (or all repos). Click **Connect**.
4. The connection status must be **Available** (not "Pending"). Copy its ARN
   (`arn:aws:codeconnections:eu-west-1:<account>:connection/<id>`).

## Create the 5 GitHub repos and push

Each service folder is already its own git repo (`git init` done, branch `main`, nothing committed). For each one
(shown with the GitHub CLI; creating them in the GitHub web UI works too):

```bash
cd ../paylab-wallet-svc
git add . && git commit -m "Initial commit"
gh repo create <GITHUB_OWNER>/paylab-wallet-svc --private --source . --push
# repeat for paylab-api-gateway, paylab-payment-svc, paylab-notify-svc, paylab-web (and paylab-infra if you like)
```

The pipelines watch the `main` branch.

## Step 8 and the CI/CD loop

```bash
CONNECTION_ARN=arn:aws:codeconnections:eu-west-1:<account>:connection/xxxx \
GITHUB_OWNER=<your-github-user-or-org> \
./08-pipelines.sh
```

Each new pipeline runs once immediately. After that, **every push to `main`** of a service repo:

1. **Source**: CodePipeline downloads the commit through the connection.
2. **Build**: CodeBuild runs the repo's `buildspec.yml`: ECR login, `docker build`, push `paylab/<svc>:<7-char commit>`
   and `:latest`, write `imagedefinitions.json` = `[{"name":"<svc>","imageUri":"..."}]`.
3. **Deploy**: the ECS action copies the service's current task definition, swaps in the new image (matched by container
   name, so `name` **must equal** the container name in `taskdef.json`), registers a new revision and does a rolling update.

Try it: change the title in `paylab-web/site/index.html`, commit, push, then watch:

```bash
aws codepipeline get-pipeline-state --name paylab-web-pipeline \
  --query 'stageStates[].[stageName,latestExecution.status]' --output table
```

**Roll back** by pointing the service at an older revision:
`aws ecs update-service --cluster paylab --service web --task-definition paylab-web:1`

> Changing **`taskdef.json` itself** (env vars, CPU, memory) is not picked up by the pipeline, which only swaps the image.
> Re-register it (re-run `./07-services.sh ..`) and then `aws ecs update-service --cluster paylab --service <svc> --task-definition paylab-<svc>`.

## Rough cost (eu-west-1, while running)

| Resource | Approx. |
|---|---|
| 5 Fargate tasks (0.25 vCPU / 0.5 GB) | ~$0.06/h |
| Application Load Balancer | ~$0.025/h + small LCU charge |
| RDS db.t4g.micro + 20 GB gp3 | ~$0.02/h |
| Public IPv4 addresses (5 tasks + ALB) | ~$0.005/h each, ~$0.04/h |
| CodePipeline V2 | ~$0.002 per action-minute (cents for a class) |
| CodeBuild (general1.small) | ~$0.005 per build-minute; each build ~1-2 min |
| SSM Parameter Store (standard), CloudWatch Logs, ECR, S3 | free to cents |
| Route 53 hosted zone (already exists) + Cloud Map private zone | $0.50/month each + tiny query costs; ACM public certificates are free |
| **Total** | **~$0.15-0.20/h, about $4 per day.** Run `./99-teardown.sh` after class! |

New accounts may get some of this on the free tier.

## Teardown

```bash
./99-teardown.sh       # type 'paylab' to confirm
```

Deletes pipelines, CodeBuild projects, the artifact bucket (emptied first), ECS services/cluster/task definitions,
the two Route 53 alias records (`pay.` and `api.`, nothing else in the zone), both listeners and the ALB, target groups `paylab-tg` and `paylab-web-tg`, RDS `paylab-db` (no final snapshot),
SSM parameters `/paylab/db/password` and `/paylab/db/host`, ECR repos, log groups, the Cloud Map services and the `paylab.internal` namespace, the four IAM roles
and the security groups. It **keeps** the hosted zone `lab.aricxpoint.co` (with its NS/SOA records), the ACM
certificate and its validation CNAMEs, so a later rebuild skips step 0. The GitHub connection is free; delete it in the console if you no longer need it.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ERROR: profile ... points at account X, but EXPECTED_ACCOUNT_ID is Y` | Wrong `AWS_PROFILE`, or SSO logged into another account. |
| Pipeline Source stage: "connection is not available" | Connection still **Pending**: finish the GitHub app install in the console. |
| Source stage can't find the repo/branch | `GITHUB_OWNER` wrong, repo not shared with the GitHub app, or branch isn't `main`. |
| CodeBuild: `Cannot connect to the Docker daemon` | `privilegedMode` must be true (the script sets it). |
| CodeBuild: `toomanyrequests` pulling `node`/`nginx` | Docker Hub anonymous rate limit on shared CodeBuild IPs. Retry the stage, or switch the `FROM` to the `public.ecr.aws/docker/library/...` mirror. |
| CodeBuild: `denied` on `docker push` | `codebuild-paylab-role` ECR permissions, or the ECR repo doesn't exist (run 04). |
| Deploy stage: "container name ... not found" | `name` in `buildspec.yml`'s `imagedefinitions.json` doesn't match the container name in `taskdef.json`. |
| Deploy stage: `iam:PassRole` denied | `codepipeline-paylab-role` needs PassRole on `ecsTaskExecutionRole` and `paylabTaskRole` (03 sets it). |
| Task stops with `CannotPullContainerError` | No public IP (`assignPublicIp=ENABLED`) or the image tag doesn't exist (did you run 06?). |
| `ResourceInitializationError: unable to pull secrets` | Execution role is missing `ssm:GetParameters` / `kms:Decrypt` for `/paylab/db/password`, or the parameter doesn't exist (run 02, 03). |
| `exec format error` | Image built for arm64 on an Apple Silicon Mac. 06 uses `--platform linux/amd64`. |
| `no pg_hba.conf entry ... no encryption` | `DB_SSL=true` missing: RDS requires TLS. |
| `password authentication failed for user "paylab"` | RDS password and `/paylab/db/password` differ. Re-run `02-database.sh` (it resets RDS if the parameter was recreated), then `aws ecs update-service --cluster paylab --service wallet-svc --force-new-deployment` (same for payment-svc). |
| Page loads but buttons show "Could not reach the API" | api-gateway unhealthy, or the `/api/*` rule is missing (re-run 05). |
| 00 waits forever for the certificate | The Cloudflare NS delegation for `lab` is missing or wrong: `dig NS lab.aricxpoint.co +short`. |
| Browser: certificate / "not secure" error | You used the ALB's `*.elb.amazonaws.com` name; use `https://pay.lab.aricxpoint.co`. |
| `getaddrinfo ENOTFOUND wallet-svc.paylab.internal` | The service has no running task yet (no A record), or it was created without `--service-registries`. Check `aws servicediscovery list-instances --service-id <id>`. |
| api-gateway returns `upstream unreachable` | An internal service isn't running or not registered in `paylab.internal` yet. DNS TTL is 10s, so it recovers on its own once the task is up. |
| Local `docker build`: `npm error Exit handler never called!`, then `Cannot find module 'express'` | npm couldn't reach the registry from inside Docker (slow network/VPN). Restart Docker Desktop or switch networks; as a temporary workaround add `ENV NODE_OPTIONS=--network-family-autoselection-attempt-timeout=3000` above `RUN npm ci`. 06 checks for this and stops before pushing a broken image. |
