#!/usr/bin/env bash
#
# ============================================================================
#  Velloxx SkillPool — POC Teardown Script
# ============================================================================
#  Destroys everything skillpool-build.sh created, in reverse dependency order.
#
#  Deletion order matters. AWS refuses to delete a VPC while any ENI still
#  references it, and ENIs are held by ECS tasks, the load balancer, RDS and
#  every interface endpoint. This script removes them in the order that works
#  and waits where a wait is genuinely required.
#
#  Usage:
#      ./skillpool-teardown.sh                    # full teardown, with prompt
#      ./skillpool-teardown.sh --endpoints-only   # just the billable endpoints
#      ./skillpool-teardown.sh --keep-data        # keep S3 buckets and RDS snapshot
#      DRY_RUN=true ./skillpool-teardown.sh       # show what would be deleted
# ============================================================================

set -uo pipefail   # deliberately not -e: teardown continues past absent resources

PROJECT="vellox-skillpool"
REGION="${AWS_REGION:-us-east-1}"
STATE_FILE="${STATE_FILE:-./skillpool-state.env}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_DATA="false"
ENDPOINTS_ONLY="false"

MEDIA_BUCKET="${PROJECT}-media-001"
LOGS_BUCKET="${PROJECT}-logs-001"
DB_IDENTIFIER="${PROJECT}-db-01"
ECS_CLUSTER="${PROJECT}-cluster-01"
ECS_SERVICE="${PROJECT}-service"
ALB_NAME="${PROJECT}-alb-01"
TG_NAME="${PROJECT}-tg"
TRAIL_NAME="${PROJECT}-audit-trail-01"
ECR_REPO="${PROJECT}-app"
LOG_GROUP="/ecs/${PROJECT}"

C_RESET='\033[0m'; C_BLUE='\033[1;34m'; C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_DIM='\033[2m'
log()  { printf "${C_BLUE}==>${C_RESET} %s\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
skip() { printf "  ${C_DIM}·${C_RESET} ${C_DIM}%s${C_RESET}\n" "$*"; }
warn() { printf "  ${C_YELLOW}!${C_RESET} %s\n" "$*"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf "${C_DIM}    [dry-run] %s${C_RESET}\n" "$*"
  else
    "$@" >/dev/null 2>&1
  fi
}

for arg in "$@"; do
  case "$arg" in
    --keep-data)      KEEP_DATA="true" ;;
    --endpoints-only) ENDPOINTS_ONLY="true" ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
  esac
done

[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  printf "${C_RED}ERROR:${C_RESET} AWS CLI not configured\n"; exit 1; }

printf "\n${C_RED}════════════════════════════════════════════════════════${C_RESET}\n"
printf "${C_RED} TEARDOWN — account %s, region %s${C_RESET}\n" "$ACCOUNT_ID" "$REGION"
printf "${C_RED}════════════════════════════════════════════════════════${C_RESET}\n"
[[ "$ENDPOINTS_ONLY" == "true" ]] && printf "  Scope: interface endpoints only\n"
[[ "$KEEP_DATA" == "true" ]] && printf "  S3 buckets and a final RDS snapshot will be kept\n"
printf "\n"

if [[ "${ASSUME_YES:-false}" != "true" && "$DRY_RUN" != "true" ]]; then
  read -r -p "Type the project name to confirm (${PROJECT}): " reply
  [[ "$reply" == "$PROJECT" ]] || { echo "Aborted."; exit 1; }
fi

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v '^None$')}"

# ---------------------------------------------------------------------------
# Interface endpoints — the biggest recurring cost, deletable on their own
# ---------------------------------------------------------------------------
delete_interface_endpoints() {
  log "Deleting interface endpoints (the ~\$0.01/hr per AZ line)"
  local ids
  ids=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-type,Values=Interface" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null)
  if [[ -z "$ids" ]]; then skip "No interface endpoints found"; return; fi
  # shellcheck disable=SC2086
  run aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $ids
  ok "Deleted: ${ids}"
  [[ "$DRY_RUN" != "true" ]] && { log "Waiting for endpoint ENIs to detach…"; sleep 45; }
}

if [[ "$ENDPOINTS_ONLY" == "true" ]]; then
  [[ -n "$VPC_ID" ]] && delete_interface_endpoints || warn "VPC not found"
  printf "\n${C_GREEN}Endpoints removed. Recreate with:${C_RESET} ./skillpool-build.sh security\n\n"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. ECS service and cluster
# ---------------------------------------------------------------------------
log "Removing ECS service and cluster"
if aws ecs describe-services --region "$REGION" --cluster "$ECS_CLUSTER" \
     --services "$ECS_SERVICE" --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
  run aws ecs update-service --region "$REGION" --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" --desired-count 0
  run aws ecs delete-service --region "$REGION" --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" --force
  ok "Service ${ECS_SERVICE} deleted"
  [[ "$DRY_RUN" != "true" ]] && { log "Waiting for tasks to stop…"; sleep 30; }
else
  skip "Service ${ECS_SERVICE} not found"
fi

for rev in $(aws ecs list-task-definitions --region "$REGION" \
    --family-prefix "${PROJECT}-task" --query 'taskDefinitionArns[]' --output text 2>/dev/null); do
  run aws ecs deregister-task-definition --region "$REGION" --task-definition "$rev"
done
ok "Task definitions deregistered"

aws ecs delete-cluster --region "$REGION" --cluster "$ECS_CLUSTER" >/dev/null 2>&1 \
  && ok "Cluster ${ECS_CLUSTER} deleted" || skip "Cluster not found"

# ---------------------------------------------------------------------------
# 2. CloudFront — must be disabled before it can be deleted
# ---------------------------------------------------------------------------
log "Removing CloudFront distribution"
CF_ID="${CF_ID:-$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${PROJECT}'].Id | [0]" --output text 2>/dev/null)}"
if [[ -n "$CF_ID" && "$CF_ID" != "None" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    printf "${C_DIM}    [dry-run] disable + delete distribution %s${C_RESET}\n" "$CF_ID"
  else
    etag=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'ETag' --output text)
    aws cloudfront get-distribution-config --id "$CF_ID" \
      --query 'DistributionConfig' --output json | jq '.Enabled=false' > /tmp/cf-disable.json
    aws cloudfront update-distribution --id "$CF_ID" \
      --distribution-config file:///tmp/cf-disable.json --if-match "$etag" >/dev/null 2>&1
    warn "Distribution ${CF_ID} disabled. Deployment takes ~15 minutes."
    warn "Delete it afterwards with:"
    warn "  etag=\$(aws cloudfront get-distribution-config --id ${CF_ID} --query ETag --output text)"
    warn "  aws cloudfront delete-distribution --id ${CF_ID} --if-match \$etag"
  fi
else
  skip "No distribution found"
fi

for oac in $(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${PROJECT}-media-oac'].Id" --output text 2>/dev/null); do
  etag=$(aws cloudfront get-origin-access-control --id "$oac" --query 'ETag' --output text 2>/dev/null)
  [[ -n "$etag" ]] && run aws cloudfront delete-origin-access-control --id "$oac" --if-match "$etag"
done

# ---------------------------------------------------------------------------
# 3. Load balancer and target group
# ---------------------------------------------------------------------------
log "Removing load balancer and target group"
alb_arn=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [[ -n "$alb_arn" && "$alb_arn" != "None" ]]; then
  run aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$alb_arn"
  ok "ALB ${ALB_NAME} deleted"
  [[ "$DRY_RUN" != "true" ]] && { log "Waiting for ALB ENIs to release…"; sleep 40; }
else
  skip "ALB not found"
fi

tg_arn=$(aws elbv2 describe-target-groups --region "$REGION" --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
if [[ -n "$tg_arn" && "$tg_arn" != "None" ]]; then
  run aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$tg_arn"
  ok "Target group ${TG_NAME} deleted"
fi

# ---------------------------------------------------------------------------
# 4. RDS
# ---------------------------------------------------------------------------
log "Removing RDS instance"
if aws rds describe-db-instances --region "$REGION" \
     --db-instance-identifier "$DB_IDENTIFIER" >/dev/null 2>&1; then
  if [[ "$KEEP_DATA" == "true" ]]; then
    snap="${DB_IDENTIFIER}-final-$(date +%Y%m%d-%H%M)"
    run aws rds delete-db-instance --region "$REGION" \
      --db-instance-identifier "$DB_IDENTIFIER" --final-db-snapshot-identifier "$snap"
    ok "RDS deleting with final snapshot ${snap}"
  else
    run aws rds delete-db-instance --region "$REGION" \
      --db-instance-identifier "$DB_IDENTIFIER" --skip-final-snapshot --delete-automated-backups
    ok "RDS deleting (no final snapshot)"
  fi
  if [[ "$DRY_RUN" != "true" ]]; then
    log "Waiting for RDS deletion (5–10 minutes)…"
    aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$DB_IDENTIFIER" 2>/dev/null
    ok "RDS deleted"
  fi
else
  skip "RDS instance not found"
fi
run aws rds delete-db-subnet-group --region "$REGION" --db-subnet-group-name "${PROJECT}-db-subnet-group"

# ---------------------------------------------------------------------------
# 5. CloudTrail, logs, ECR, secret
# ---------------------------------------------------------------------------
log "Removing CloudTrail, log group, ECR repository and secret"
run aws cloudtrail stop-logging --region "$REGION" --name "$TRAIL_NAME"
run aws cloudtrail delete-trail --region "$REGION" --name "$TRAIL_NAME"
ok "Trail removed"

run aws logs delete-log-group --region "$REGION" --log-group-name "$LOG_GROUP"
ok "Log group removed"

run aws ecr delete-repository --region "$REGION" --repository-name "$ECR_REPO" --force
ok "ECR repository removed"

run aws athena delete-work-group --region "$REGION" --work-group "${PROJECT}-auditors" --recursive-delete-option
ok "Athena workgroup removed"

if [[ "$KEEP_DATA" == "true" ]]; then
  skip "Secret retained (--keep-data)"
else
  run aws secretsmanager delete-secret --region "$REGION" \
    --secret-id "${PROJECT}-db" --force-delete-without-recovery
  ok "Secret removed"
fi

# ---------------------------------------------------------------------------
# 6. S3 buckets
# ---------------------------------------------------------------------------
if [[ "$KEEP_DATA" == "true" ]]; then
  log "Keeping S3 buckets (--keep-data)"
else
  log "Emptying and removing S3 buckets"
  for b in "$MEDIA_BUCKET" "$LOGS_BUCKET"; do
    if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
      if [[ "$DRY_RUN" == "true" ]]; then
        printf "${C_DIM}    [dry-run] empty and delete s3://%s${C_RESET}\n" "$b"
      else
        # Versioned buckets need every version and delete marker removed first.
        aws s3api list-object-versions --bucket "$b" \
          --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
          | jq -c '. | select(.Objects != null)' | while read -r batch; do
              aws s3api delete-objects --bucket "$b" --delete "$batch" >/dev/null 2>&1
            done
        aws s3api list-object-versions --bucket "$b" \
          --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
          | jq -c '. | select(.Objects != null)' | while read -r batch; do
              aws s3api delete-objects --bucket "$b" --delete "$batch" >/dev/null 2>&1
            done
        aws s3 rm "s3://${b}" --recursive >/dev/null 2>&1
        aws s3api delete-bucket --bucket "$b" >/dev/null 2>&1 && ok "Bucket ${b} deleted" \
          || warn "Bucket ${b} could not be deleted — check for remaining objects"
      fi
    else
      skip "Bucket ${b} not found"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 7. IAM
# ---------------------------------------------------------------------------
log "Removing IAM roles and groups"
for role in "${PROJECT}-ecs-s3-role" "${PROJECT}-ecs-execution-role"; do
  for p in $(aws iam list-role-policies --role-name "$role" \
      --query 'PolicyNames[]' --output text 2>/dev/null); do
    run aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  for a in $(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    run aws iam detach-role-policy --role-name "$role" --policy-arn "$a"
  done
  run aws iam delete-role --role-name "$role"
  ok "Role ${role} removed"
done

for g in "${PROJECT}-multimedia-users" "${PROJECT}-appdev-devops-users" \
         "${PROJECT}-db-users" "${PROJECT}-auditors"; do
  for p in $(aws iam list-group-policies --group-name "$g" \
      --query 'PolicyNames[]' --output text 2>/dev/null); do
    run aws iam delete-group-policy --group-name "$g" --policy-name "$p"
  done
  for u in $(aws iam get-group --group-name "$g" \
      --query 'Users[].UserName' --output text 2>/dev/null); do
    run aws iam remove-user-from-group --group-name "$g" --user-name "$u"
  done
  run aws iam delete-group --group-name "$g"
  ok "Group ${g} removed"
done

# ---------------------------------------------------------------------------
# 8. Network — last, because everything above held an ENI in it
# ---------------------------------------------------------------------------
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  warn "VPC not found — skipping network teardown"
else
  log "Removing VPC endpoints, subnets, gateways and the VPC"
  eps=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null)
  if [[ -n "$eps" ]]; then
    # shellcheck disable=SC2086
    run aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $eps
    ok "Endpoints removed"
    [[ "$DRY_RUN" != "true" ]] && sleep 45
  fi

  igw=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | grep -v '^None$')
  if [[ -n "$igw" ]]; then
    run aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
    run aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw"
    ok "Internet gateway removed"
  fi

  for s in $(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
    run aws ec2 delete-subnet --region "$REGION" --subnet-id "$s"
  done
  ok "Subnets removed"

  for rt in $(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' \
      --output text 2>/dev/null); do
    run aws ec2 delete-route-table --region "$REGION" --route-table-id "$rt"
  done
  ok "Route tables removed"

  # Revoke cross-referencing rules first, or the groups refuse to delete.
  sgs=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)
  for sg in $sgs; do
    perms=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
    [[ "$perms" != "[]" && -n "$perms" ]] && \
      run aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$sg" --ip-permissions "$perms"
    eperms=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
    [[ "$eperms" != "[]" && -n "$eperms" ]] && \
      run aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$sg" --ip-permissions "$eperms"
  done
  for sg in $sgs; do run aws ec2 delete-security-group --region "$REGION" --group-id "$sg"; done
  ok "Security groups removed"

  if run aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"; then
    ok "VPC ${VPC_ID} deleted"
  else
    warn "VPC ${VPC_ID} still has dependencies. Find them with:"
    warn "  aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=${VPC_ID} \\"
    warn "    --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description}'"
  fi
fi

[[ "$DRY_RUN" != "true" && "$KEEP_DATA" != "true" ]] && rm -f "$STATE_FILE"

printf "\n${C_GREEN}Teardown complete.${C_RESET}\n"
printf "${C_DIM}Confirm nothing remains:\n"
printf "  aws resourcegroupstaggingapi get-resources --region %s \\\n" "$REGION"
printf "    --tag-filters Key=Project,Values=%s --query 'ResourceTagMappingList[].ResourceARN'${C_RESET}\n\n" "$PROJECT"
