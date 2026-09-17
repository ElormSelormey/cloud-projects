#!/usr/bin/env bash
#
# ============================================================================
#  Velloxx SkillPool — Proof of Concept Environment Build Script
# ============================================================================
#  Rebuilds the entire POC infrastructure from scratch using the AWS CLI,
#  matching the architecture documented in the POC Build Guide (v2).
#
#  Design notes baked into this script (the hard-won ones):
#    * No NAT Gateway. Private subnets reach AWS services via VPC endpoints.
#    * Interface endpoints are created with EXPLICIT subnet IDs — passing only
#      an AZ produces an endpoint with no ENI and DNS that never resolves.
#    * The S3 gateway endpoint is associated with BOTH private route tables.
#      ECR image layers are fetched from S3 via a presigned URL, so a private
#      subnet without the S3 route cannot pull a container image.
#    * ecs-sg egress uses the AWS-managed S3 prefix list, not the VPC CIDR.
#      Gateway endpoint traffic is addressed to S3's real public IP ranges.
#    * The CloudWatch log group is created before the task definition. ECS does
#      not create it, and the execution role is not granted CreateLogGroup.
#    * Secrets Manager ARNs carry a random 6-character suffix, so IAM policies
#      must end in a wildcard.
#    * DB_HOST is the full RDS endpoint hostname, never the DB identifier.
#
#  Usage:
#      ./skillpool-build.sh                 # run every enabled phase
#      ./skillpool-build.sh network iam     # run named phases only
#      ./skillpool-build.sh --list          # show phase names
#      DRY_RUN=true ./skillpool-build.sh    # print actions, change nothing
#
#  Requires: aws cli v2, jq, and (for the image phase) docker.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — edit this block, nothing below it
# ---------------------------------------------------------------------------
PROJECT="vellox-skillpool"
REGION="${AWS_REGION:-us-east-1}"
AZ_A="${REGION}a"
AZ_B="${REGION}b"

# S3 bucket names are globally unique. Change the suffix for a fresh account.
BUCKET_SUFFIX="001"
MEDIA_BUCKET="${PROJECT}-media-${BUCKET_SUFFIX}"
LOGS_BUCKET="${PROJECT}-logs-${BUCKET_SUFFIX}"

VPC_CIDR="10.0.0.0/16"
SUBNET_PUBLIC_A="10.0.0.0/20"
SUBNET_PUBLIC_B="10.0.16.0/20"
SUBNET_APP_A="10.0.128.0/20"
SUBNET_APP_B="10.0.144.0/20"
SUBNET_DATA_A="10.0.200.0/24"
SUBNET_DATA_B="10.0.201.0/24"

# Database
DB_IDENTIFIER="${PROJECT}-db-01"
DB_NAME="skillpool"
DB_USERNAME="admin"
DB_INSTANCE_CLASS="db.t4g.micro"
DB_ENGINE_VERSION="8.0"
DB_STORAGE_GB=20
DB_MULTI_AZ="false"          # POC setting. Production: true.

# Compute
ECR_REPO="${PROJECT}-app"
ECS_CLUSTER="${PROJECT}-cluster-01"
ECS_SERVICE="${PROJECT}-service"
TASK_FAMILY="${PROJECT}-task"
CONTAINER_NAME="${PROJECT}-app"
CONTAINER_PORT=5000
TASK_CPU="256"               # 0.25 vCPU
TASK_MEMORY="512"            # 0.5 GB
DESIRED_COUNT=1
LOG_GROUP="/ecs/${PROJECT}"
LOG_RETENTION_DAYS=7

# Load balancing
ALB_NAME="${PROJECT}-alb-01"
TG_NAME="${PROJECT}-tg"
HEALTH_CHECK_PATH="/health"

# Audit
TRAIL_NAME="${PROJECT}-audit-trail-01"
ATHENA_DB="${PROJECT//-/_}_audit"

# Local application source (for the image build phase)
PROJECT_DIR="${PROJECT_DIR:-$HOME/Web App Development/vellox-skillpool-project}"

# Cost guardrail
BUDGET_LIMIT_USD="40"
BUDGET_EMAIL="${BUDGET_EMAIL:-}"   # set this to enable budget alerts

# Endpoint AZ coverage: "single" (~$28/mo) or "dual" (~$56/mo)
ENDPOINT_AZ_COVERAGE="dual"

# Optional / slower phases
ENABLE_CLOUDFRONT="true"
ENABLE_CLOUDTRAIL="true"
ENABLE_ATHENA="true"
ENABLE_BUDGET="false"

DRY_RUN="${DRY_RUN:-false}"
STATE_FILE="${STATE_FILE:-./skillpool-state.env}"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
C_RESET='\033[0m'; C_BLUE='\033[1;34m'; C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_DIM='\033[2m'

log()   { printf "${C_BLUE}==>${C_RESET} %s\n" "$*"; }
ok()    { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
skip()  { printf "  ${C_DIM}·${C_RESET} ${C_DIM}%s${C_RESET}\n" "$*"; }
warn()  { printf "  ${C_YELLOW}!${C_RESET} %s\n" "$*"; }
die()   { printf "${C_RED}ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }

aws_() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf "${C_DIM}    [dry-run] aws %s${C_RESET}\n" "$*" >&2
    echo "dry-run-placeholder"
  else
    aws "$@"
  fi
}

save_state() {
  local key="$1" val="$2"
  touch "$STATE_FILE"
  grep -v "^export ${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "export ${key}=\"${val}\"" >> "$STATE_FILE"
  export "${key}=${val}"
}

load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true; }

# Return the id of a resource tagged Name=<value>, or empty string.
find_by_name() {
  local resource="$1" name="$2" query="$3"
  aws ec2 "describe-${resource}" --region "$REGION" \
    --filters "Name=tag:Name,Values=${name}" \
    --query "$query" --output text 2>/dev/null | grep -v '^None$' || true
}

tag_it() {
  local id="$1" name="$2"
  aws_ ec2 create-tags --region "$REGION" --resources "$id" \
    --tags "Key=Name,Value=${name}" "Key=Project,Value=${PROJECT}" \
           "Key=Environment,Value=poc" "Key=ManagedBy,Value=skillpool-build-script" >/dev/null
}

require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# ---------------------------------------------------------------------------
# PHASE: preflight
# ---------------------------------------------------------------------------
phase_preflight() {
  log "Preflight checks"
  require aws
  require jq

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || die "AWS CLI is not configured. Run 'aws configure' first."
  CALLER=$(aws sts get-caller-identity --query Arn --output text)
  save_state ACCOUNT_ID "$ACCOUNT_ID"
  save_state REGION "$REGION"

  ok "Account ${ACCOUNT_ID} in ${REGION}"
  ok "Identity ${CALLER}"

  # This is the check that would have caught the wrong-account incident.
  printf "\n  ${C_YELLOW}Building into account %s (%s).${C_RESET}\n" "$ACCOUNT_ID" "$REGION"
  if [[ "${ASSUME_YES:-false}" != "true" && "$DRY_RUN" != "true" ]]; then
    read -r -p "  Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted by user."
  fi

  # ECS needs its service-linked role to exist before a cluster can be created.
  if ! aws iam get-role --role-name AWSServiceRoleForECS >/dev/null 2>&1; then
    log "Creating the ECS service-linked role"
    aws_ iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 || true
    sleep 10
    ok "AWSServiceRoleForECS created"
  else
    skip "AWSServiceRoleForECS already exists"
  fi
}

# ---------------------------------------------------------------------------
# PHASE: network
# ---------------------------------------------------------------------------
phase_network() {
  log "Phase 1 — VPC, subnets, gateway, route tables, endpoints"

  # ---- VPC ----
  VPC_ID=$(find_by_name vpcs "${PROJECT}-vpc" 'Vpcs[0].VpcId')
  if [[ -z "$VPC_ID" ]]; then
    VPC_ID=$(aws_ ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" \
      --query 'Vpc.VpcId' --output text)
    tag_it "$VPC_ID" "${PROJECT}-vpc"
    # Both must be on or private endpoint DNS will never resolve.
    aws_ ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support   >/dev/null
    aws_ ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null
    ok "VPC ${VPC_ID} (${VPC_CIDR}), DNS support and hostnames enabled"
  else
    skip "VPC ${VPC_ID} already exists"
  fi
  save_state VPC_ID "$VPC_ID"

  # ---- Subnets ----
  make_subnet() {
    local cidr="$1" az="$2" name="$3" varname="$4"
    local id
    id=$(find_by_name subnets "$name" 'Subnets[0].SubnetId')
    if [[ -z "$id" ]]; then
      id=$(aws_ ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
        --cidr-block "$cidr" --availability-zone "$az" \
        --query 'Subnet.SubnetId' --output text)
      tag_it "$id" "$name"
      ok "Subnet ${name} ${id} (${cidr}, ${az})"
    else
      skip "Subnet ${name} ${id} already exists"
    fi
    save_state "$varname" "$id"
  }

  make_subnet "$SUBNET_PUBLIC_A" "$AZ_A" "${PROJECT}-subnet-public1-${AZ_A}"  SUBNET_PUB_A_ID
  make_subnet "$SUBNET_PUBLIC_B" "$AZ_B" "${PROJECT}-subnet-public2-${AZ_B}"  SUBNET_PUB_B_ID
  make_subnet "$SUBNET_APP_A"    "$AZ_A" "${PROJECT}-subnet-private1-${AZ_A}" SUBNET_APP_A_ID
  make_subnet "$SUBNET_APP_B"    "$AZ_B" "${PROJECT}-subnet-private2-${AZ_B}" SUBNET_APP_B_ID
  make_subnet "$SUBNET_DATA_A"   "$AZ_A" "${PROJECT}-rds-subnet-az01"         SUBNET_DATA_A_ID
  make_subnet "$SUBNET_DATA_B"   "$AZ_B" "${PROJECT}-rds-subnet-az02"         SUBNET_DATA_B_ID

  # ---- Internet gateway ----
  IGW_ID=$(find_by_name internet-gateways "${PROJECT}-igw" 'InternetGateways[0].InternetGatewayId')
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID=$(aws_ ec2 create-internet-gateway --region "$REGION" \
      --query 'InternetGateway.InternetGatewayId' --output text)
    tag_it "$IGW_ID" "${PROJECT}-igw"
    aws_ ec2 attach-internet-gateway --region "$REGION" \
      --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null
    ok "Internet gateway ${IGW_ID} attached"
  else
    skip "Internet gateway ${IGW_ID} already exists"
  fi
  save_state IGW_ID "$IGW_ID"

  # ---- Route tables ----
  make_rtb() {
    local name="$1" varname="$2"
    local id
    id=$(find_by_name route-tables "$name" 'RouteTables[0].RouteTableId')
    if [[ -z "$id" ]]; then
      id=$(aws_ ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
        --query 'RouteTable.RouteTableId' --output text)
      tag_it "$id" "$name"
      ok "Route table ${name} ${id}"
    else
      skip "Route table ${name} ${id} already exists"
    fi
    save_state "$varname" "$id"
  }
  make_rtb "${PROJECT}-rtb-public"             RTB_PUBLIC_ID
  make_rtb "${PROJECT}-rtb-private1-${AZ_A}"   RTB_PRIV_A_ID
  make_rtb "${PROJECT}-rtb-private2-${AZ_B}"   RTB_PRIV_B_ID

  # Public route table gets the only internet route in the whole VPC.
  aws_ ec2 create-route --region "$REGION" --route-table-id "$RTB_PUBLIC_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null 2>&1 || true

  associate() {
    aws_ ec2 associate-route-table --region "$REGION" \
      --route-table-id "$1" --subnet-id "$2" >/dev/null 2>&1 || true
  }
  associate "$RTB_PUBLIC_ID" "$SUBNET_PUB_A_ID"
  associate "$RTB_PUBLIC_ID" "$SUBNET_PUB_B_ID"
  associate "$RTB_PRIV_A_ID" "$SUBNET_APP_A_ID"
  associate "$RTB_PRIV_A_ID" "$SUBNET_DATA_A_ID"
  associate "$RTB_PRIV_B_ID" "$SUBNET_APP_B_ID"
  associate "$RTB_PRIV_B_ID" "$SUBNET_DATA_B_ID"
  ok "Subnet associations applied (public routes via IGW, private routes local only)"
}

# ---------------------------------------------------------------------------
# PHASE: security  (security groups + endpoints, which depend on them)
# ---------------------------------------------------------------------------
phase_security() {
  log "Phase 2a — Security groups"
  load_state

  make_sg() {
    local name="$1" desc="$2" varname="$3"
    local id
    id=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)
    if [[ -z "$id" ]]; then
      id=$(aws_ ec2 create-security-group --region "$REGION" --group-name "$name" \
        --description "$desc" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
      tag_it "$id" "$name"
      ok "Security group ${name} ${id}"
    else
      skip "Security group ${name} ${id} already exists"
    fi
    save_state "$varname" "$id"
  }

  make_sg "${PROJECT}-alb-sg"      "Public entry point for the ALB"       ALB_SG_ID
  make_sg "${PROJECT}-ecs-sg"      "ECS Fargate application tier"         ECS_SG_ID
  make_sg "${PROJECT}-rds-sg"      "RDS MySQL data tier"                  RDS_SG_ID
  make_sg "${PROJECT}-endpoint-sg" "VPC interface endpoint access"        EP_SG_ID

  ingress() {
    aws_ ec2 authorize-security-group-ingress --region "$REGION" --group-id "$1" \
      --ip-permissions "$2" >/dev/null 2>&1 || true
  }

  # ALB: open to the world on 80/443
  ingress "$ALB_SG_ID" 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTP from internet"}]'
  ingress "$ALB_SG_ID" 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTPS from internet"}]'

  # Each tier below is reachable only from the tier above it, by SG reference.
  ingress "$ECS_SG_ID" "IpProtocol=tcp,FromPort=${CONTAINER_PORT},ToPort=${CONTAINER_PORT},UserIdGroupPairs=[{GroupId=${ALB_SG_ID},Description=\"App port from ALB only\"}]"
  ingress "$RDS_SG_ID" "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=${ECS_SG_ID},Description=\"MySQL from ECS only\"}]"
  ingress "$EP_SG_ID"  "IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId=${ECS_SG_ID},Description=\"HTTPS from ECS to endpoints\"}]"
  ok "Ingress rules applied (internet → ALB → ECS → RDS, ECS → endpoints)"

  # ---- Egress: the rule set that defect 6 turned on ----
  # A gateway endpoint does NOT rewrite the destination address. Traffic to S3
  # is still addressed to S3's public ranges, so a rule scoped to the VPC CIDR
  # silently drops ECR layer downloads. The managed prefix list is the correct
  # scope: exactly S3's ranges, nothing else.
  S3_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
    --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.s3" \
    --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null | grep -v '^None$' || true)

  if [[ -n "$S3_PREFIX_LIST" && "$DRY_RUN" != "true" ]]; then
    # Replace the default allow-all egress with scoped rules.
    aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$ECS_SG_ID" \
      --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null 2>&1 || true

    egress() {
      aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$ECS_SG_ID" \
        --ip-permissions "$1" >/dev/null 2>&1 || true
    }
    egress "IpProtocol=tcp,FromPort=443,ToPort=443,PrefixListIds=[{PrefixListId=${S3_PREFIX_LIST},Description=\"S3 and ECR layers via gateway endpoint\"}]"
    egress "IpProtocol=tcp,FromPort=443,ToPort=443,UserIdGroupPairs=[{GroupId=${EP_SG_ID},Description=\"Interface endpoints\"}]"
    egress "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=${RDS_SG_ID},Description=\"RDS MySQL\"}]"
    egress "IpProtocol=udp,FromPort=53,ToPort=53,IpRanges=[{CidrIp=${VPC_CIDR},Description=\"VPC DNS resolver\"}]"
    egress "IpProtocol=tcp,FromPort=53,ToPort=53,IpRanges=[{CidrIp=${VPC_CIDR},Description=\"VPC DNS resolver\"}]"
    ok "ECS egress scoped to S3 prefix list ${S3_PREFIX_LIST}, endpoints, RDS and DNS"
  else
    warn "S3 managed prefix list not found — leaving default allow-all egress in place"
  fi

  # ---- VPC endpoints ----
  log "Phase 2b — VPC endpoints (no NAT Gateway in this design)"

  # S3 gateway endpoint. MUST be associated with BOTH private route tables:
  # a task in a subnet whose route table lacks this route cannot pull an image.
  local s3_ep
  s3_ep=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.s3" \
              "Name=vpc-endpoint-type,Values=Gateway" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null | grep -v '^None$' || true)
  if [[ -z "$s3_ep" ]]; then
    s3_ep=$(aws_ ec2 create-vpc-endpoint --region "$REGION" --vpc-id "$VPC_ID" \
      --service-name "com.amazonaws.${REGION}.s3" \
      --vpc-endpoint-type Gateway \
      --route-table-ids "$RTB_PRIV_A_ID" "$RTB_PRIV_B_ID" \
      --query 'VpcEndpoint.VpcEndpointId' --output text)
    tag_it "$s3_ep" "${PROJECT}-vpc-s3-endpoints-01"
    ok "S3 gateway endpoint ${s3_ep} on both private route tables (free)"
  else
    skip "S3 gateway endpoint ${s3_ep} already exists"
  fi
  save_state S3_ENDPOINT_ID "$s3_ep"

  # Interface endpoints. Subnet IDs are passed explicitly — this is the step
  # that, done through the console, silently produces an endpoint with no ENI.
  local ep_subnets
  if [[ "$ENDPOINT_AZ_COVERAGE" == "dual" ]]; then
    ep_subnets="$SUBNET_APP_A_ID $SUBNET_APP_B_ID"
  else
    ep_subnets="$SUBNET_APP_A_ID"
  fi

  for svc in ecr.api ecr.dkr logs secretsmanager; do
    local name="${PROJECT}-${svc}-endpoint-01"
    local existing
    existing=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.${svc}" \
      --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null | grep -v '^None$' || true)
    if [[ -n "$existing" ]]; then
      skip "Interface endpoint ${svc} ${existing} already exists"
      continue
    fi
    local id
    # shellcheck disable=SC2086
    id=$(aws_ ec2 create-vpc-endpoint --region "$REGION" --vpc-id "$VPC_ID" \
      --service-name "com.amazonaws.${REGION}.${svc}" \
      --vpc-endpoint-type Interface \
      --subnet-ids $ep_subnets \
      --security-group-ids "$EP_SG_ID" \
      --private-dns-enabled \
      --query 'VpcEndpoint.VpcEndpointId' --output text)
    tag_it "$id" "$name"
    ok "Interface endpoint ${svc} ${id} (private DNS on, ${ENDPOINT_AZ_COVERAGE}-AZ)"
  done

  warn "Interface endpoints bill ~\$0.01/hr per AZ each. Set ENDPOINT_AZ_COVERAGE=single to halve it."
}

# ---------------------------------------------------------------------------
# PHASE: iam
# ---------------------------------------------------------------------------
phase_iam() {
  log "Phase 2c — IAM roles and segmented access groups"
  load_state
  local tmp; tmp=$(mktemp -d)

  # ---- ECS task role: what the running container can do ----
  cat > "${tmp}/ecs-trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

  make_role() {
    local role="$1"
    if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
      skip "Role ${role} already exists"
    else
      aws_ iam create-role --role-name "$role" \
        --assume-role-policy-document "file://${tmp}/ecs-trust.json" \
        --tags "Key=Project,Value=${PROJECT}" >/dev/null
      ok "Role ${role} created"
    fi
  }

  TASK_ROLE="${PROJECT}-ecs-s3-role"
  EXEC_ROLE="${PROJECT}-ecs-execution-role"
  make_role "$TASK_ROLE"
  make_role "$EXEC_ROLE"
  save_state TASK_ROLE "$TASK_ROLE"
  save_state EXEC_ROLE "$EXEC_ROLE"

  cat > "${tmp}/task-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],
  "Resource":"arn:aws:s3:::${MEDIA_BUCKET}/*"},
 {"Effect":"Allow","Action":["s3:ListBucket"],
  "Resource":"arn:aws:s3:::${MEDIA_BUCKET}"},
 {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}*"}]}
JSON
  aws_ iam put-role-policy --role-name "$TASK_ROLE" \
    --policy-name "${PROJECT}-task-access" \
    --policy-document "file://${tmp}/task-policy.json" >/dev/null
  ok "Task role scoped to the media bucket and its log group"

  # ---- Execution role: what ECS itself does on the task's behalf ----
  aws_ iam attach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null 2>&1 || true

  # Secrets Manager appends a random 6-char suffix to every secret ARN, so an
  # exact-match resource never matches. The trailing wildcard is required.
  cat > "${tmp}/exec-secrets.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],
  "Resource":"arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${PROJECT}-db-*"}]}
JSON
  aws_ iam put-role-policy --role-name "$EXEC_ROLE" \
    --policy-name "${PROJECT}-secrets-access" \
    --policy-document "file://${tmp}/exec-secrets.json" >/dev/null
  ok "Execution role has ECR pull, log write and scoped secret read"

  # ---- Four segmented human access groups ----
  cat > "${tmp}/g-multimedia.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["s3:PutObject","s3:GetObject","s3:ListBucket","s3:DeleteObject"],
 "Resource":["arn:aws:s3:::${MEDIA_BUCKET}","arn:aws:s3:::${MEDIA_BUCKET}/*"]}]}
JSON
  cat > "${tmp}/g-appdev.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["ecs:*","ecr:*","logs:*","elasticloadbalancing:Describe*","iam:PassRole"],
 "Resource":"*"}]}
JSON
  cat > "${tmp}/g-db.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["rds:Describe*","ssm:StartSession"],"Resource":"*"}]}
JSON
  cat > "${tmp}/g-audit.json" <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["athena:*","glue:Get*","glue:Batch*"],"Resource":"*"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],
  "Resource":["arn:aws:s3:::${LOGS_BUCKET}","arn:aws:s3:::${LOGS_BUCKET}/*"]}]}
JSON

  make_group() {
    local group="$1" policy="$2" file="$3"
    if aws iam get-group --group-name "$group" >/dev/null 2>&1; then
      skip "Group ${group} already exists"
    else
      aws_ iam create-group --group-name "$group" >/dev/null
      ok "Group ${group} created"
    fi
    aws_ iam put-group-policy --group-name "$group" \
      --policy-name "$policy" --policy-document "file://${file}" >/dev/null
  }

  make_group "${PROJECT}-multimedia-users"     "${PROJECT}-multimedia-access" "${tmp}/g-multimedia.json"
  make_group "${PROJECT}-appdev-devops-users"  "${PROJECT}-appdev-access"     "${tmp}/g-appdev.json"
  make_group "${PROJECT}-db-users"             "${PROJECT}-db-access"         "${tmp}/g-db.json"
  make_group "${PROJECT}-auditors"             "${PROJECT}-auditor-access"    "${tmp}/g-audit.json"
  ok "Four segmented access domains in place"

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# PHASE: storage
# ---------------------------------------------------------------------------
phase_storage() {
  log "Phase 4 — S3 buckets"
  load_state

  make_bucket() {
    local bucket="$1"
    if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
      skip "Bucket ${bucket} already exists"
      return
    fi
    if [[ "$REGION" == "us-east-1" ]]; then
      aws_ s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null
    else
      aws_ s3api create-bucket --bucket "$bucket" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
    aws_ s3api put-public-access-block --bucket "$bucket" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
    aws_ s3api put-bucket-ownership-controls --bucket "$bucket" \
      --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null
    aws_ s3api put-bucket-encryption --bucket "$bucket" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
    ok "Bucket ${bucket} (public access blocked, ACLs disabled, SSE-S3)"
  }

  make_bucket "$MEDIA_BUCKET"
  make_bucket "$LOGS_BUCKET"

  aws_ s3api put-bucket-versioning --bucket "$MEDIA_BUCKET" \
    --versioning-configuration Status=Enabled >/dev/null
  ok "Versioning enabled on the media bucket"

  save_state MEDIA_BUCKET "$MEDIA_BUCKET"
  save_state LOGS_BUCKET "$LOGS_BUCKET"
}

# ---------------------------------------------------------------------------
# PHASE: database
# ---------------------------------------------------------------------------
phase_database() {
  log "Phase 3 — Secrets Manager and RDS MySQL"
  load_state

  # ---- Secret ----
  SECRET_NAME="${PROJECT}-db"
  local secret_arn
  secret_arn=$(aws secretsmanager describe-secret --region "$REGION" \
    --secret-id "$SECRET_NAME" --query 'ARN' --output text 2>/dev/null || true)

  if [[ -z "$secret_arn" || "$secret_arn" == "None" ]]; then
    DB_PASSWORD=$(aws secretsmanager get-random-password --region "$REGION" \
      --password-length 24 --exclude-punctuation --require-each-included-type \
      --query 'RandomPassword' --output text)
    secret_arn=$(aws_ secretsmanager create-secret --region "$REGION" \
      --name "$SECRET_NAME" \
      --description "Velloxx SkillPool RDS master credentials" \
      --secret-string "{\"username\":\"${DB_USERNAME}\",\"password\":\"${DB_PASSWORD}\"}" \
      --query 'ARN' --output text)
    ok "Secret ${SECRET_NAME} created with a generated password"
  else
    DB_PASSWORD=$(aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "$SECRET_NAME" --query 'SecretString' --output text | jq -r '.password')
    skip "Secret ${SECRET_NAME} already exists — reusing it"
  fi
  save_state SECRET_ARN "$secret_arn"

  # ---- Subnet group across the two data-tier subnets ----
  local sng="${PROJECT}-db-subnet-group"
  if ! aws rds describe-db-subnet-groups --region "$REGION" \
        --db-subnet-group-name "$sng" >/dev/null 2>&1; then
    aws_ rds create-db-subnet-group --region "$REGION" \
      --db-subnet-group-name "$sng" \
      --db-subnet-group-description "SkillPool data tier subnets" \
      --subnet-ids "$SUBNET_DATA_A_ID" "$SUBNET_DATA_B_ID" >/dev/null
    ok "DB subnet group ${sng}"
  else
    skip "DB subnet group ${sng} already exists"
  fi

  # ---- Instance ----
  if aws rds describe-db-instances --region "$REGION" \
       --db-instance-identifier "$DB_IDENTIFIER" >/dev/null 2>&1; then
    skip "RDS instance ${DB_IDENTIFIER} already exists"
  else
    aws_ rds create-db-instance --region "$REGION" \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --db-instance-class "$DB_INSTANCE_CLASS" \
      --engine mysql --engine-version "$DB_ENGINE_VERSION" \
      --master-username "$DB_USERNAME" \
      --master-user-password "$DB_PASSWORD" \
      --allocated-storage "$DB_STORAGE_GB" --storage-type gp3 \
      --db-name "$DB_NAME" \
      --db-subnet-group-name "$sng" \
      --vpc-security-group-ids "$RDS_SG_ID" \
      --no-publicly-accessible \
      --backup-retention-period 7 \
      --storage-encrypted \
      --multi-az="$DB_MULTI_AZ" \
      --tags "Key=Project,Value=${PROJECT}" >/dev/null
    ok "RDS ${DB_IDENTIFIER} creating (${DB_INSTANCE_CLASS}, Multi-AZ=${DB_MULTI_AZ}, not public)"

    if [[ "$DRY_RUN" != "true" ]]; then
      log "Waiting for RDS to become available (typically 5–10 minutes)…"
      aws rds wait db-instance-available --region "$REGION" \
        --db-instance-identifier "$DB_IDENTIFIER"
    fi
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    DB_ENDPOINT=$(aws rds describe-db-instances --region "$REGION" \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --query 'DBInstances[0].Endpoint.Address' --output text)
    save_state DB_ENDPOINT "$DB_ENDPOINT"
    # The full endpoint hostname, never the DB identifier — that was the cause
    # of the Internal Server Error on the search page.
    ok "RDS endpoint ${DB_ENDPOINT}"
  fi
}

# ---------------------------------------------------------------------------
# PHASE: registry  (ECR + optional image build and push)
# ---------------------------------------------------------------------------
phase_registry() {
  log "Phase 5a — ECR repository and container image"
  load_state

  if aws ecr describe-repositories --region "$REGION" \
       --repository-names "$ECR_REPO" >/dev/null 2>&1; then
    skip "ECR repository ${ECR_REPO} already exists"
  else
    aws_ ecr create-repository --region "$REGION" --repository-name "$ECR_REPO" \
      --image-scanning-configuration scanOnPush=true \
      --tags "Key=Project,Value=${PROJECT}" >/dev/null
    ok "ECR repository ${ECR_REPO}"
  fi

  local uri="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
  save_state IMAGE_URI "${uri}:latest"

  if [[ ! -d "$PROJECT_DIR" ]]; then
    warn "Application source not found at: ${PROJECT_DIR}"
    warn "Skipping image build. Set PROJECT_DIR and re-run: ./skillpool-build.sh registry"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not installed — skipping image build"
    return
  fi

  log "Building and pushing the container image"
  if [[ "$DRY_RUN" != "true" ]]; then
    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
    ( cd "$PROJECT_DIR" && docker build -t "${ECR_REPO}:latest" . )
    docker tag "${ECR_REPO}:latest" "${uri}:latest"
    docker push "${uri}:latest"
  fi
  ok "Image pushed to ${uri}:latest"
}

# ---------------------------------------------------------------------------
# PHASE: loadbalancer
# ---------------------------------------------------------------------------
phase_loadbalancer() {
  log "Phase 6 — Application Load Balancer and target group"
  load_state

  local alb_arn
  alb_arn=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || true)

  if [[ -z "$alb_arn" || "$alb_arn" == "None" ]]; then
    alb_arn=$(aws_ elbv2 create-load-balancer --region "$REGION" --name "$ALB_NAME" \
      --subnets "$SUBNET_PUB_A_ID" "$SUBNET_PUB_B_ID" \
      --security-groups "$ALB_SG_ID" \
      --scheme internet-facing --type application --ip-address-type ipv4 \
      --tags "Key=Project,Value=${PROJECT}" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    ok "ALB ${ALB_NAME} created"
  else
    skip "ALB ${ALB_NAME} already exists"
  fi
  save_state ALB_ARN "$alb_arn"

  local tg_arn
  tg_arn=$(aws elbv2 describe-target-groups --region "$REGION" \
    --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

  if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
    # Target type MUST be 'ip' — Fargate uses awsvpc networking.
    tg_arn=$(aws_ elbv2 create-target-group --region "$REGION" --name "$TG_NAME" \
      --protocol HTTP --port "$CONTAINER_PORT" --vpc-id "$VPC_ID" \
      --target-type ip \
      --health-check-protocol HTTP --health-check-path "$HEALTH_CHECK_PATH" \
      --health-check-interval-seconds 30 --healthy-threshold-count 2 \
      --unhealthy-threshold-count 3 --matcher 'HttpCode=200' \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
    ok "Target group ${TG_NAME} (type ip, health check ${HEALTH_CHECK_PATH})"
  else
    skip "Target group ${TG_NAME} already exists"
  fi
  save_state TG_ARN "$tg_arn"

  if [[ "$DRY_RUN" != "true" ]]; then
    local listeners
    listeners=$(aws elbv2 describe-listeners --region "$REGION" \
      --load-balancer-arn "$alb_arn" --query 'length(Listeners)' --output text 2>/dev/null || echo 0)
    if [[ "$listeners" == "0" ]]; then
      aws elbv2 create-listener --region "$REGION" --load-balancer-arn "$alb_arn" \
        --protocol HTTP --port 80 \
        --default-actions "Type=forward,TargetGroupArn=${tg_arn}" >/dev/null
      ok "HTTP :80 listener forwarding to the target group"
    else
      skip "Listener already exists"
    fi

    ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --load-balancer-arns "$alb_arn" --query 'LoadBalancers[0].DNSName' --output text)
    save_state ALB_DNS "$ALB_DNS"
    ok "ALB DNS ${ALB_DNS}"
  fi
}

# ---------------------------------------------------------------------------
# PHASE: compute  (log group, cluster, task definition, service)
# ---------------------------------------------------------------------------
phase_compute() {
  log "Phase 5b — CloudWatch log group, ECS cluster, task definition and service"
  load_state

  # The log group must exist first. ECS will not create it, and the execution
  # role is not granted logs:CreateLogGroup.
  if aws logs describe-log-groups --region "$REGION" \
       --log-group-name-prefix "$LOG_GROUP" \
       --query "logGroups[?logGroupName=='${LOG_GROUP}'] | length(@)" \
       --output text 2>/dev/null | grep -q '^1$'; then
    skip "Log group ${LOG_GROUP} already exists"
  else
    aws_ logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP" >/dev/null
    aws_ logs put-retention-policy --region "$REGION" --log-group-name "$LOG_GROUP" \
      --retention-in-days "$LOG_RETENTION_DAYS" >/dev/null
    ok "Log group ${LOG_GROUP} (${LOG_RETENTION_DAYS}-day retention)"
  fi

  if aws ecs describe-clusters --region "$REGION" --clusters "$ECS_CLUSTER" \
       --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    skip "Cluster ${ECS_CLUSTER} already exists"
  else
    aws_ ecs create-cluster --region "$REGION" --cluster-name "$ECS_CLUSTER" \
      --capacity-providers FARGATE FARGATE_SPOT \
      --tags "key=Project,value=${PROJECT}" >/dev/null
    ok "ECS cluster ${ECS_CLUSTER}"
  fi

  [[ "$DRY_RUN" == "true" ]] && { warn "Dry run — skipping task definition and service"; return; }

  local tmp; tmp=$(mktemp -d)
  cat > "${tmp}/taskdef.json" <<JSON
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${TASK_CPU}",
  "memory": "${TASK_MEMORY}",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}",
  "taskRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE}",
  "containerDefinitions": [
    {
      "name": "${CONTAINER_NAME}",
      "image": "${IMAGE_URI}",
      "essential": true,
      "portMappings": [{ "containerPort": ${CONTAINER_PORT}, "protocol": "tcp" }],
      "environment": [
        { "name": "DB_HOST",           "value": "${DB_ENDPOINT}" },
        { "name": "DB_NAME",           "value": "${DB_NAME}" },
        { "name": "STORAGE_MODE",      "value": "s3" },
        { "name": "S3_BUCKET",         "value": "${MEDIA_BUCKET}" },
        { "name": "CLOUDFRONT_DOMAIN", "value": "${CLOUDFRONT_DOMAIN:-}" }
      ],
      "secrets": [
        { "name": "DB_USER",     "valueFrom": "${SECRET_ARN}:username::" },
        { "name": "DB_PASSWORD", "valueFrom": "${SECRET_ARN}:password::" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "app"
        }
      }
    }
  ]
}
JSON

  local td_arn
  td_arn=$(aws ecs register-task-definition --region "$REGION" \
    --cli-input-json "file://${tmp}/taskdef.json" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
  save_state TASK_DEF_ARN "$td_arn"
  ok "Task definition registered: ${td_arn##*/}"
  rm -rf "$tmp"

  local svc_status
  svc_status=$(aws ecs describe-services --region "$REGION" --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" --query 'services[0].status' --output text 2>/dev/null || echo "NONE")

  if [[ "$svc_status" == "ACTIVE" ]]; then
    aws ecs update-service --region "$REGION" --cluster "$ECS_CLUSTER" \
      --service "$ECS_SERVICE" --task-definition "$td_arn" \
      --force-new-deployment >/dev/null
    ok "Existing service updated to the new task definition"
  else
    aws ecs create-service --region "$REGION" --cluster "$ECS_CLUSTER" \
      --service-name "$ECS_SERVICE" --task-definition "$td_arn" \
      --desired-count "$DESIRED_COUNT" --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_APP_A_ID},${SUBNET_APP_B_ID}],securityGroups=[${ECS_SG_ID}],assignPublicIp=DISABLED}" \
      --load-balancers "targetGroupArn=${TG_ARN},containerName=${CONTAINER_NAME},containerPort=${CONTAINER_PORT}" \
      --health-check-grace-period-seconds 60 \
      --tags "key=Project,value=${PROJECT}" >/dev/null
    ok "Service ${ECS_SERVICE} created (no public IP, behind the ALB)"
  fi

  log "Waiting for the service to reach a steady state…"
  if aws ecs wait services-stable --region "$REGION" \
       --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" 2>/dev/null; then
    ok "Service is stable"
  else
    warn "Service did not stabilise in time. Check events:"
    warn "  aws ecs describe-services --cluster ${ECS_CLUSTER} --services ${ECS_SERVICE} \\"
    warn "    --query 'services[0].events[:5].message' --output text"
  fi
}

# ---------------------------------------------------------------------------
# PHASE: cloudfront  (dual origin — ALB default, S3 on /media/* via OAC)
# ---------------------------------------------------------------------------
phase_cloudfront() {
  [[ "$ENABLE_CLOUDFRONT" != "true" ]] && { skip "CloudFront disabled in config"; return; }
  log "Phase 7 — CloudFront dual-origin distribution with Origin Access Control"
  load_state
  [[ "$DRY_RUN" == "true" ]] && { warn "Dry run — skipping CloudFront"; return; }

  local oac_name="${PROJECT}-media-oac"
  local oac_id
  oac_id=$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${oac_name}'].Id | [0]" --output text 2>/dev/null || true)

  if [[ -z "$oac_id" || "$oac_id" == "None" ]]; then
    oac_id=$(aws cloudfront create-origin-access-control \
      --origin-access-control-config "{\"Name\":\"${oac_name}\",\"Description\":\"SkillPool media bucket\",\"SigningProtocol\":\"sigv4\",\"SigningBehavior\":\"always\",\"OriginAccessControlOriginType\":\"s3\"}" \
      --query 'OriginAccessControl.Id' --output text)
    ok "Origin Access Control ${oac_id}"
  else
    skip "Origin Access Control ${oac_id} already exists"
  fi

  local existing
  existing=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${PROJECT}'].Id | [0]" --output text 2>/dev/null || true)

  if [[ -n "$existing" && "$existing" != "None" ]]; then
    skip "Distribution ${existing} already exists"
    CF_ID="$existing"
  else
    local tmp; tmp=$(mktemp -d)
    cat > "${tmp}/cf.json" <<JSON
{
  "CallerReference": "${PROJECT}-$(date +%s)",
  "Comment": "${PROJECT}",
  "Enabled": true,
  "Origins": {
    "Quantity": 2,
    "Items": [
      {
        "Id": "alb-origin",
        "DomainName": "${ALB_DNS}",
        "CustomOriginConfig": {
          "HTTPPort": 80, "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] }
        }
      },
      {
        "Id": "s3-media-origin",
        "DomainName": "${MEDIA_BUCKET}.s3.${REGION}.amazonaws.com",
        "OriginAccessControlId": "${oac_id}",
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] }
    },
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
    "Compress": true
  },
  "CacheBehaviors": {
    "Quantity": 1,
    "Items": [
      {
        "PathPattern": "/media/*",
        "TargetOriginId": "s3-media-origin",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
          "Quantity": 2, "Items": ["GET","HEAD"],
          "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] }
        },
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
        "Compress": true
      }
    ]
  },
  "PriceClass": "PriceClass_All"
}
JSON
    CF_ID=$(aws cloudfront create-distribution --distribution-config "file://${tmp}/cf.json" \
      --query 'Distribution.Id' --output text)
    rm -rf "$tmp"
    ok "Distribution ${CF_ID} created (deploying — allow 5–15 minutes)"
  fi

  CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" \
    --query 'Distribution.DomainName' --output text)
  save_state CF_ID "$CF_ID"
  save_state CLOUDFRONT_DOMAIN "$CLOUDFRONT_DOMAIN"
  ok "CloudFront domain ${CLOUDFRONT_DOMAIN}"

  # Bucket policy: CloudFront OAC read, plus the ECS task role for uploads.
  local tmp2; tmp2=$(mktemp -d)
  cat > "${tmp2}/bucket-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipal",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${MEDIA_BUCKET}/*",
      "Condition": {
        "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_ID}" }
      }
    },
    {
      "Sid": "AllowECSTaskRoleAccess",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE}" },
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${MEDIA_BUCKET}/*"
    }
  ]
}
JSON
  aws s3api put-bucket-policy --bucket "$MEDIA_BUCKET" \
    --policy "file://${tmp2}/bucket-policy.json" >/dev/null
  rm -rf "$tmp2"
  ok "Media bucket policy: CloudFront OAC read + ECS task role write"

  warn "Re-run './skillpool-build.sh compute' to inject CLOUDFRONT_DOMAIN into the task definition."
}

# ---------------------------------------------------------------------------
# PHASE: audit  (CloudTrail + Athena)
# ---------------------------------------------------------------------------
phase_audit() {
  log "Phase 8 — CloudTrail data events and Athena"
  load_state
  [[ "$DRY_RUN" == "true" ]] && { warn "Dry run — skipping audit setup"; return; }

  if [[ "$ENABLE_CLOUDTRAIL" == "true" ]]; then
    local tmp; tmp=$(mktemp -d)
    cat > "${tmp}/trail-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AWSCloudTrailAclCheck", "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::${LOGS_BUCKET}" },
    { "Sid": "AWSCloudTrailWrite", "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${LOGS_BUCKET}/AWSLogs/${ACCOUNT_ID}/*",
      "Condition": { "StringEquals": { "s3:x-amz-acl": "bucket-owner-full-control" } } }
  ]
}
JSON
    aws s3api put-bucket-policy --bucket "$LOGS_BUCKET" \
      --policy "file://${tmp}/trail-policy.json" >/dev/null
    rm -rf "$tmp"
    ok "Logs bucket policy allows CloudTrail delivery"

    if aws cloudtrail describe-trails --region "$REGION" \
         --trail-name-list "$TRAIL_NAME" \
         --query 'trailList[0].Name' --output text 2>/dev/null | grep -q "$TRAIL_NAME"; then
      skip "Trail ${TRAIL_NAME} already exists"
    else
      aws cloudtrail create-trail --region "$REGION" --name "$TRAIL_NAME" \
        --s3-bucket-name "$LOGS_BUCKET" --is-multi-region-trail \
        --enable-log-file-validation >/dev/null
      ok "Trail ${TRAIL_NAME} created (multi-region, log file validation on)"
    fi

    # Data events are NOT on by default. This is the setting that actually
    # answers "who accessed which candidate photograph, and when".
    aws cloudtrail put-event-selectors --region "$REGION" --trail-name "$TRAIL_NAME" \
      --advanced-event-selectors "[
        {\"Name\":\"Management events\",
         \"FieldSelectors\":[{\"Field\":\"eventCategory\",\"Equals\":[\"Management\"]}]},
        {\"Name\":\"Media bucket object access\",
         \"FieldSelectors\":[
           {\"Field\":\"eventCategory\",\"Equals\":[\"Data\"]},
           {\"Field\":\"resources.type\",\"Equals\":[\"AWS::S3::Object\"]},
           {\"Field\":\"resources.ARN\",\"StartsWith\":[\"arn:aws:s3:::${MEDIA_BUCKET}/\"]}]}
      ]" >/dev/null
    ok "S3 data events enabled on the media bucket"

    aws cloudtrail start-logging --region "$REGION" --name "$TRAIL_NAME" >/dev/null
    ok "Trail is logging"
  fi

  if [[ "$ENABLE_ATHENA" == "true" ]]; then
    local results="s3://${LOGS_BUCKET}/athena-results/"
    local wg="${PROJECT}-auditors"
    if aws athena get-work-group --region "$REGION" --work-group "$wg" >/dev/null 2>&1; then
      skip "Athena workgroup ${wg} already exists"
    else
      aws athena create-work-group --region "$REGION" --name "$wg" \
        --configuration "ResultConfiguration={OutputLocation=${results}}" \
        --description "Auditor queries over CloudTrail logs" >/dev/null
      ok "Athena workgroup ${wg} (results to ${results})"
    fi

    local qid
    qid=$(aws athena start-query-execution --region "$REGION" --work-group "$wg" \
      --query-string "CREATE DATABASE IF NOT EXISTS ${ATHENA_DB}" \
      --query 'QueryExecutionId' --output text 2>/dev/null || true)
    [[ -n "$qid" ]] && ok "Athena database ${ATHENA_DB} requested (query ${qid})"

    warn "Create the CloudTrail table in Athena with the DDL in the build guide (Phase 8, step 3)."
  fi
}

# ---------------------------------------------------------------------------
# PHASE: budget
# ---------------------------------------------------------------------------
phase_budget() {
  [[ "$ENABLE_BUDGET" != "true" ]] && { skip "Budget disabled in config"; return; }
  [[ -z "$BUDGET_EMAIL" ]] && { warn "BUDGET_EMAIL not set — skipping budget"; return; }
  log "Cost guardrail — AWS Budget with alerts"
  load_state
  [[ "$DRY_RUN" == "true" ]] && return

  local tmp; tmp=$(mktemp -d)
  cat > "${tmp}/budget.json" <<JSON
{ "BudgetName": "${PROJECT}-poc-budget",
  "BudgetLimit": { "Amount": "${BUDGET_LIMIT_USD}", "Unit": "USD" },
  "TimeUnit": "MONTHLY", "BudgetType": "COST" }
JSON
  cat > "${tmp}/notifications.json" <<JSON
[ $(for t in 50 80 100; do
      printf '{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":%s,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"%s"}]}' "$t" "$BUDGET_EMAIL"
      [[ $t -ne 100 ]] && printf ','
    done) ]
JSON
  aws budgets create-budget --account-id "$ACCOUNT_ID" \
    --budget "file://${tmp}/budget.json" \
    --notifications-with-subscribers "file://${tmp}/notifications.json" >/dev/null 2>&1 \
    && ok "Budget of \$${BUDGET_LIMIT_USD}/month with alerts at 50/80/100%" \
    || skip "Budget already exists"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# PHASE: summary
# ---------------------------------------------------------------------------
phase_summary() {
  load_state
  printf "\n${C_BLUE}%s${C_RESET}\n" "════════════════════════════════════════════════════════════"
  printf "${C_GREEN} Velloxx SkillPool POC — build complete${C_RESET}\n"
  printf "${C_BLUE}%s${C_RESET}\n\n" "════════════════════════════════════════════════════════════"
  printf "  Account            %s (%s)\n" "${ACCOUNT_ID:-?}" "$REGION"
  printf "  VPC                %s\n"      "${VPC_ID:-?}"
  printf "  RDS endpoint       %s\n"      "${DB_ENDPOINT:-not yet available}"
  printf "  Media bucket       %s\n"      "${MEDIA_BUCKET}"
  printf "  Logs bucket        %s\n"      "${LOGS_BUCKET}"
  printf "  Image              %s\n"      "${IMAGE_URI:-?}"
  printf "\n  ${C_GREEN}Application URL${C_RESET}    http://%s\n" "${ALB_DNS:-not yet available}"
  [[ -n "${CLOUDFRONT_DOMAIN:-}" ]] && printf "  ${C_GREEN}CloudFront URL${C_RESET}     https://%s\n" "$CLOUDFRONT_DOMAIN"
  printf "\n  State written to   %s\n\n" "$STATE_FILE"

  printf "${C_YELLOW}  Remaining manual steps${C_RESET}\n"
  printf "    1. Seed the database. RDS has no public endpoint, so connect from inside\n"
  printf "       the VPC (bastion or VPC-attached CloudShell) and run:\n"
  printf "         mysql -h %s -u %s -p %s < db/schema.sql\n" "${DB_ENDPOINT:-<endpoint>}" "$DB_USERNAME" "$DB_NAME"
  printf "       Retrieve the password with:\n"
  printf "         aws secretsmanager get-secret-value --secret-id %s-db \\\n" "$PROJECT"
  printf "           --query SecretString --output text | jq -r .password\n"
  printf "    2. Create the Athena table over CloudTrail logs (build guide, Phase 8).\n"
  printf "    3. Deploy WAF before any production go-live — not included here by design.\n\n"

  printf "${C_DIM}  Verify with:\n"
  printf "    aws elbv2 describe-target-health --target-group-arn %s \\\n" "${TG_ARN:-<tg-arn>}"
  printf "      --query 'TargetHealthDescriptions[].TargetHealth.State'\n"
  printf "    curl -I http://%s%s${C_RESET}\n\n" "${ALB_DNS:-<alb-dns>}" "$HEALTH_CHECK_PATH"
}

# ---------------------------------------------------------------------------
# DRIVER
# ---------------------------------------------------------------------------
ALL_PHASES=(preflight network security iam storage database registry loadbalancer compute cloudfront audit budget summary)

usage() {
  cat <<EOF
Velloxx SkillPool — POC build script

  ./skillpool-build.sh                run every phase in order
  ./skillpool-build.sh <phase>...     run only the named phases
  ./skillpool-build.sh --list         list phase names
  DRY_RUN=true ./skillpool-build.sh   print actions without changing anything
  ASSUME_YES=true ./skillpool-build.sh   skip the account confirmation prompt

Phases: ${ALL_PHASES[*]}

Every phase is idempotent — re-running skips resources that already exist.
EOF
}

main() {
  if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${ALL_PHASES[@]}"; exit 0; fi
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

  [[ "$DRY_RUN" == "true" ]] && warn "DRY RUN — no resources will be created"

  local phases=("${ALL_PHASES[@]}")
  if [[ $# -gt 0 ]]; then
    phases=("preflight" "$@")
    [[ " $* " == *" summary "* ]] || phases+=("summary")
  fi

  local start; start=$(date +%s)
  for p in "${phases[@]}"; do
    if ! declare -F "phase_${p}" >/dev/null; then die "Unknown phase: ${p}"; fi
    "phase_${p}"
    echo
  done
  printf "${C_DIM}Elapsed: %ss${C_RESET}\n" "$(( $(date +%s) - start ))"
}

main "$@"
