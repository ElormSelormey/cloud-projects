# Velloxx SkillPool — Infrastructure Scripts

Two scripts that rebuild and destroy the entire POC environment with the AWS CLI, matching the architecture in the POC Build Guide (v2).

| File | Purpose |
|---|---|
| `skillpool-build.sh` | Provisions everything, phase by phase. Idempotent. |
| `skillpool-teardown.sh` | Destroys everything in reverse dependency order. |
| `skillpool-state.env` | Written by the build; holds resource IDs for later phases and teardown. |

---

## Prerequisites

```bash
aws --version          # v2.x
jq --version           # required for JSON handling
docker --version       # only needed for the image build phase
aws sts get-caller-identity   # confirm you're in the RIGHT account
```

That last command matters. The build script prints the account ID and asks you to confirm before creating anything — that check exists because it is genuinely easy to have the CLI pointed at one account while the browser console shows another.

---

## Quick start

```bash
chmod +x skillpool-build.sh skillpool-teardown.sh

# See what would happen, change nothing
DRY_RUN=true ./skillpool-build.sh

# Build everything (~15–20 minutes, mostly waiting on RDS)
./skillpool-build.sh
```

Point it at your application source before the image phase:

```bash
export PROJECT_DIR="$HOME/Web App Development/vellox-skillpool-project"
./skillpool-build.sh
```

---

## Phases

Run them all, or name the ones you want. `preflight` always runs first.

| Phase | Creates |
|---|---|
| `preflight` | Account check, ECS service-linked role |
| `network` | VPC, 6 subnets, IGW, 3 route tables |
| `security` | 4 security groups, S3 gateway endpoint, 4 interface endpoints |
| `iam` | Task role, execution role, 4 segmented access groups |
| `storage` | Media and logs buckets (public access blocked, ACLs disabled) |
| `database` | Secrets Manager secret, DB subnet group, RDS MySQL |
| `registry` | ECR repository; builds and pushes the image if `PROJECT_DIR` exists |
| `loadbalancer` | ALB, target group (type `ip`), HTTP listener |
| `compute` | Log group, ECS cluster, task definition, service |
| `cloudfront` | OAC, dual-origin distribution, media bucket policy |
| `audit` | CloudTrail with S3 data events, Athena workgroup |
| `budget` | Monthly budget with 50/80/100% alerts (off by default) |

```bash
./skillpool-build.sh --list             # phase names
./skillpool-build.sh network security    # just the networking
./skillpool-build.sh compute             # redeploy the service only
```

---

## Configuration

Edit the block at the top of `skillpool-build.sh`. The settings most worth knowing:

```bash
BUCKET_SUFFIX="001"            # change for a fresh account — bucket names are global
ENDPOINT_AZ_COVERAGE="dual"    # "single" halves endpoint cost (~$56/mo → ~$28/mo)
DB_MULTI_AZ="false"            # POC setting; "true" for production
DESIRED_COUNT=1                # raise for HA
ENABLE_CLOUDFRONT="true"
ENABLE_BUDGET="false"          # set BUDGET_EMAIL to use it
```

---

## The six defects this script encodes

Each of these cost real debugging time during the manual build. The script handles all of them, which is the main argument for using it over the console.

**1. Interface endpoints created without subnets.** In the console, ticking an Availability Zone checkbox does not select a subnet — you must also pick one from that row's dropdown. An endpoint with no subnet has no network interface anywhere in the VPC, so its DNS name never resolves and dependent services fail with `no such host`. The script passes `--subnet-ids` explicitly.

**2. Endpoint security group missing inbound 443.** DNS resolves, then the connection times out with `context deadline exceeded`. The script creates `endpoint-sg` with inbound 443 from `ecs-sg` by security-group reference.

**3. CloudWatch log group does not exist.** ECS does not create it, and the default execution role policy grants `CreateLogStream` but not `CreateLogGroup`. The script creates the group before registering the task definition.

**4. Secrets Manager ARN wildcard.** Every secret ARN carries a random six-character suffix beyond the name you chose, so an exact-match resource in an IAM policy never matches. The script's policy resource ends in `-db-*`.

**5. Execution role missing ECR permissions.** A role with custom S3 and logs policies still cannot call `ecr:GetAuthorizationToken`. The script attaches the AWS-managed `AmazonECSTaskExecutionRolePolicy`.

**6. S3 gateway endpoint routing and egress scope.** This is the subtle one. ECR image *layers* are not fetched through the ECR endpoints — they come from an AWS-managed S3 bucket via a presigned URL. Two things follow:

- The S3 gateway endpoint must be associated with **both** private route tables, or a task in the uncovered subnet cannot pull its image.
- A gateway endpoint does **not** rewrite the destination address. Traffic is still addressed to S3's real public IP ranges and merely routed internally, so a security group egress rule scoped to the VPC CIDR silently blocks it. The script scopes egress to the **AWS-managed S3 prefix list** — exactly S3's ranges, nothing else — rather than opening `0.0.0.0/0`.

A seventh issue was application-level: `DB_HOST` was set to the RDS *instance identifier* rather than the full endpoint hostname. The script reads the real endpoint from the RDS API and injects that.

---

## After the build

Two things the script deliberately cannot do for you.

**Seed the database.** RDS has no public endpoint by design, so this must run from inside the VPC — a bastion host or a VPC-attached CloudShell session:

```bash
aws secretsmanager get-secret-value --secret-id vellox-skillpool-db \
  --query SecretString --output text | jq -r .password

mysql -h <rds-endpoint> -u admin -p skillpool < db/schema.sql
```

**Create the Athena table** over the CloudTrail logs, using the DDL in Phase 8 of the build guide.

Verify the deployment:

```bash
source ./skillpool-state.env

aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].TargetHealth.State'      # want: healthy

curl -I "http://${ALB_DNS}/health"                             # want: 200

aws logs tail /ecs/vellox-skillpool --follow
```

---

## Teardown

```bash
./skillpool-teardown.sh                    # everything, with a typed confirmation
./skillpool-teardown.sh --keep-data        # keep buckets + take a final RDS snapshot
./skillpool-teardown.sh --endpoints-only   # just the billable interface endpoints
DRY_RUN=true ./skillpool-teardown.sh       # show what would be deleted
```

`--endpoints-only` is the one you will use most. The four interface endpoints are roughly 47% of the POC run rate and are the sensible thing to remove between working sessions:

```bash
./skillpool-teardown.sh --endpoints-only   # stop the meter
./skillpool-build.sh security              # bring them back, ~2 minutes
```

Deletion order is not arbitrary. AWS refuses to delete a VPC while any elastic network interface still references it, and ENIs are held by ECS tasks, the load balancer, RDS and every interface endpoint — so the script removes those first and waits where a wait is genuinely needed.

**CloudFront is the exception to full automation.** A distribution must be disabled and fully redeployed before it can be deleted, which takes about 15 minutes. The script disables it and prints the two commands to finish the job later.

Confirm nothing was left behind:

```bash
aws resourcegroupstaggingapi get-resources --region us-east-1 \
  --tag-filters Key=Project,Values=vellox-skillpool \
  --query 'ResourceTagMappingList[].ResourceARN'
```

---

## What this is not

This is a POC provisioning script, not production infrastructure-as-code. For anything beyond a demonstration you want Terraform or CloudFormation, which track state properly, plan changes before applying them, and detect drift. The value here is that it is readable end to end and encodes exactly what was learned building this environment by hand — treat it as executable documentation of the POC, and as the starting point for a proper IaC module rather than a substitute for one.

Two things it deliberately omits, both documented in the design: **AWS WAF** (not free-tier eligible, and should be added before any production go-live) and **Multi-AZ RDS** (set `DB_MULTI_AZ="true"` to enable).
