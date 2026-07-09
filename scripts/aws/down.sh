#!/bin/bash

############################################################################
#
#    Agno AWS Teardown — ECS Express Mode
#
#    Usage:
#      ./scripts/aws/down.sh          # asks before destroying
#      ./scripts/aws/down.sh --yes    # no prompt (CI / automation)
#
#    Deletes the Express service (which removes its ALB listener rules,
#    target groups, SGs, and autoscaling), the RDS instance (ALL DATA),
#    the ECR repo, the Secrets Manager secrets, and the CloudWatch log
#    group. AWS bills idle resources — run this when an environment is
#    done, and verify with the commands printed at the end.
#
#    Overrides: AWS_REGION (default: us-east-1)
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
RED='\033[31m'
NC='\033[0m'

ECR_REPO="agentos"
RDS_INSTANCE="agentos-db"
RDS_SUBNET_GROUP="agentos-db-subnets"
RDS_SG_NAME="agentos-rds-sg"
STATE_FILE="tmp/agentos-aws.state"
SECRETS=(agentos/openai-api-key agentos/db-pass agentos/jwt-verification-key agentos/parallel-api-key agentos/slack-bot-token agentos/slack-signing-secret agentos/mcp-connect-secret agentos/agentos-mcp-signing-key)

# Preflight
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Install v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Region precedence: explicit AWS_REGION > the region up.sh recorded in the
# state file > default. A region mismatch would make every delete report
# not-found while the real resources keep billing in the deploy region.
REGION="$AWS_REGION"
[[ -z "$REGION" && -f "$STATE_FILE" ]] && REGION="$(sed -nE 's/^REGION=(.*)$/\1/p' "$STATE_FILE" | head -1)"
REGION="${REGION:-us-east-1}"

# Service ARN: state file first (machine-local), then the env files up.sh
# persists it into (survives fresh clones and cleaned tmp/).
SERVICE_ARN=""
[[ -f "$STATE_FILE" ]] && SERVICE_ARN="$(sed -nE 's/^SERVICE_ARN=(.*)$/\1/p' "$STATE_FILE" | head -1)"
if [[ -z "$SERVICE_ARN" ]]; then
    for f in .env.production .env; do
        [[ -f "$f" ]] && SERVICE_ARN="$(sed -nE 's/^SERVICE_ARN=(.*)$/\1/p' "$f" | head -1)" && [[ -n "$SERVICE_ARN" ]] && break
    done
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}AWS Teardown${NC}"
echo ""
echo -e "This deletes from region ${REGION}:"
echo -e "  - Express service    ${SERVICE_ARN:-<no ARN in ${STATE_FILE} — will skip>}"
echo -e "  - RDS instance       ${RDS_INSTANCE}  ${RED}(all data deleted, no final snapshot)${NC}"
echo -e "  - ECR repo           ${ECR_REPO} (all images)"
echo -e "  - Secrets            ${SECRETS[*]}"
echo -e "  - Log group          /ecs/agent-os"
echo -e "  - DB subnet group    ${RDS_SUBNET_GROUP}, security group ${RDS_SG_NAME}"
echo ""

if [[ "$1" != "--yes" ]]; then
    printf "Type the RDS instance name (%s) to confirm: " "$RDS_INSTANCE"
    IFS= read -r CONFIRM
    if [[ "$CONFIRM" != "$RDS_INSTANCE" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Stop the cost driver FIRST. RDS is the expensive resource; issue its delete
# BEFORE the Express-service drain wait so a slow drain (which can exceed the
# bound below — live drains have taken >30 min) never strands the database
# running. Deletion is async; we wait for it near the end, so the DB drains in
# parallel with the service teardown.
echo ""
echo -e "${BOLD}Deleting RDS instance (async — drains while the service tears down)...${NC}"
RDS_DELETING=""
if RDS_DEL_ERR="$(aws rds delete-db-instance --region "$REGION" \
    --db-instance-identifier "$RDS_INSTANCE" \
    --skip-final-snapshot --delete-automated-backups 2>&1 > /dev/null)"; then
    RDS_DELETING=1
elif grep -qiE 'not.?found|DBInstanceNotFound' <<< "$RDS_DEL_ERR"; then
    echo -e "${DIM}Instance already gone${NC}"
else
    # A real failure (deletion protection, invalid state, throttling) — do NOT
    # swallow it as "already gone": the DB may still be running and billing.
    echo -e "${RED}${BOLD}Warning: RDS delete did not succeed${NC} — the database may still be billing:"
    echo -e "${DIM}${RDS_DEL_ERR}${NC}"
    echo -e "${DIM}  Retry: aws rds delete-db-instance --region ${REGION} --db-instance-identifier ${RDS_INSTANCE} --skip-final-snapshot --delete-automated-backups${NC}"
fi

if [[ -n "$SERVICE_ARN" ]]; then
    echo ""
    echo -e "${BOLD}Deleting Express service (removes ALB listener rules, SGs, autoscaling)...${NC}"
    # Capture stderr: on a retry after a timed-out earlier run, the service is
    # already gone and delete fails with "Resource not found" — skip the drain
    # wait entirely then. (A deleted service can stay *describable* as
    # DRAINING long after it left list-services, so polling would spin.)
    STATUS="ACTIVE"
    if ! DELETE_ERR="$(aws ecs delete-express-gateway-service --region "$REGION" \
        --service-arn "$SERVICE_ARN" 2>&1 > /dev/null)"; then
        if grep -qi 'not found' <<< "$DELETE_ERR"; then
            echo -e "${DIM}Service already gone.${NC}"
            STATUS="GONE"
        else
            echo -e "${DIM}${DELETE_ERR}${NC}"
            echo -e "${DIM}Delete failed — verify below${NC}"
        fi
    fi
    if [[ "$STATUS" != "GONE" ]]; then
        echo -e "${DIM}Waiting for the service to drain (up to 40 min)...${NC}"
        # 40 min bound: Express unwinds its ALB wiring here and live drains have
        # exceeded 30 min. A timeout is NON-FATAL (was `exit 1`, which stranded
        # RDS): RDS is already deleting above, and the ALB sweep + subnet/SG/
        # ECR/secret/log deletes below still run so nothing is left billing.
        for _ in $(seq 1 240); do
            STATUS="$(aws ecs describe-express-gateway-service --region "$REGION" \
                --service-arn "$SERVICE_ARN" \
                --query 'service.status.statusCode' --output text 2> /dev/null || echo GONE)"
            # Terminal states: describe fails once the service is fully
            # removed (GONE), and INACTIVE is the API's deleted state.
            if [[ "$STATUS" == "GONE" || "$STATUS" == "None" || "$STATUS" == "INACTIVE" ]]; then
                break
            fi
            sleep 10
        done
    fi
    if [[ "$STATUS" == "GONE" || "$STATUS" == "None" || "$STATUS" == "INACTIVE" ]]; then
        rm -f "$STATE_FILE"
    else
        echo -e "${RED}${BOLD}Service still ${STATUS} after 40 minutes${NC} — it finishes deleting"
        echo -e "asynchronously. Keeping ${STATE_FILE}; continuing teardown so nothing is left"
        echo -e "billing. Re-run ./scripts/aws/down.sh --yes later to confirm the service is gone."
        echo -e "${DIM}  ARN: ${SERVICE_ARN}${NC}"
    fi
else
    echo -e "${DIM}No service ARN recorded — if a service exists, delete it with:${NC}"
    echo -e "${DIM}  aws ecs delete-express-gateway-service --region ${REGION} --service-arn <arn>${NC}"
fi

# Orphaned shared Express gateway ALB. ECS Express provisions a shared,
# AmazonECSManaged ALB ("up to 25 services share one"); deleting the last
# Express service does NOT remove it — it lingers and bills (~$17-25/mo), and
# `describe-express-gateway-service` reports stale DRAINING forever. Remove it,
# its target groups, and its SG — scoped PER ALB: only delete an express-gateway
# ALB when every target group attached to it has 0 registered targets, so a
# shared ALB still serving another Express service is never touched. (A
# region-wide ECS-service count would wrongly leave the ALB billing whenever any
# unrelated ECS service exists.)
alb_removed=""
for alb_arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'express-gateway')].LoadBalancerArn" \
    --output text 2> /dev/null); do
    managed="$(aws elbv2 describe-tags --resource-arns "$alb_arn" --region "$REGION" \
        --query "TagDescriptions[0].Tags[?Key=='AmazonECSManaged'].Value | [0]" --output text 2> /dev/null)"
    [[ "$managed" != "true" ]] && continue
    # Capture target groups BEFORE deleting the ALB (afterwards the
    # LoadBalancerArns filter no longer matches).
    TGS="$(aws elbv2 describe-target-groups --region "$REGION" \
        --query "TargetGroups[?contains(LoadBalancerArns, '${alb_arn}')].TargetGroupArn" \
        --output text 2> /dev/null)"
    in_use=""
    for tg in $TGS; do
        cnt="$(aws elbv2 describe-target-health --target-group-arn "$tg" --region "$REGION" \
            --query 'length(TargetHealthDescriptions)' --output text 2> /dev/null || echo 0)"
        [[ -n "$cnt" && "$cnt" != "0" ]] && in_use=1 || true
    done
    if [[ -n "$in_use" ]]; then
        echo -e "${DIM}Express gateway ALB still has registered targets — leaving it in place.${NC}"
        continue
    fi
    echo ""
    echo -e "${BOLD}Removing orphaned Express gateway ALB (no registered targets)...${NC}"
    if aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn" --region "$REGION" > /dev/null 2>&1; then
        echo -e "${DIM}  Deleted ALB${NC}"
        alb_removed=1
    fi
    # Listener/rule refs clear a beat after the ALB delete — retry the TGs.
    for tg in $TGS; do
        for _ in 1 2 3 4 5 6; do
            aws elbv2 delete-target-group --target-group-arn "$tg" --region "$REGION" > /dev/null 2>&1 \
                && { echo -e "${DIM}  Deleted target group ${tg##*/}${NC}"; break; }
            sleep 10
        done
    done
done
# The ALB's own SG — only if we actually removed an ALB. ELB releases the SG a
# while after the ALB is gone; retry, then leave a manual hint if it's still held
# (a security group is free — not billing — so a leftover is cosmetic).
if [[ -n "$alb_removed" ]]; then
    ALB_SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
        --filters 'Name=group-name,Values=ecs-express-gateway-alb-*' \
        --query 'SecurityGroups[0].GroupId' --output text 2> /dev/null || true)"
    if [[ -n "$ALB_SG_ID" && "$ALB_SG_ID" != "None" ]]; then
        sg_deleted=""
        for _ in 1 2 3 4 5 6 7 8; do
            aws ec2 delete-security-group --region "$REGION" --group-id "$ALB_SG_ID" > /dev/null 2>&1 \
                && { echo -e "${DIM}  Deleted ALB security group ${ALB_SG_ID}${NC}"; sg_deleted=1; break; }
            sleep 15
        done
        if [[ -z "$sg_deleted" ]]; then
            echo -e "${DIM}  ALB security group ${ALB_SG_ID} still held by ELB cleanup (free, not billing); delete later:${NC}"
            echo -e "${DIM}    aws ec2 delete-security-group --region ${REGION} --group-id ${ALB_SG_ID}${NC}"
        fi
    fi
fi

# Finish RDS teardown — the delete was issued first, above, and has been
# draining in parallel with the service teardown.
if [[ -n "$RDS_DELETING" ]]; then
    echo ""
    echo -e "${BOLD}Waiting for the RDS instance to finish deleting...${NC}"
    aws rds wait db-instance-deleted --db-instance-identifier "$RDS_INSTANCE" --region "$REGION" \
        || true
fi

aws rds delete-db-subnet-group --db-subnet-group-name "$RDS_SUBNET_GROUP" --region "$REGION" 2> /dev/null \
    || echo -e "${DIM}Subnet group already gone${NC}"

RDS_SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters Name=group-name,Values="$RDS_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2> /dev/null || true)"
if [[ -n "$RDS_SG_ID" && "$RDS_SG_ID" != "None" ]]; then
    aws ec2 delete-security-group --region "$REGION" --group-id "$RDS_SG_ID" > /dev/null 2>&1 \
        || echo -e "${DIM}Security group ${RDS_SG_ID} still referenced — delete it after the service SGs are gone:${NC}\n${DIM}  aws ec2 delete-security-group --region ${REGION} --group-id ${RDS_SG_ID}${NC}"
fi

echo ""
echo -e "${BOLD}Deleting ECR repo...${NC}"
aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" --force > /dev/null 2>&1 \
    || echo -e "${DIM}Repo already gone${NC}"

echo ""
echo -e "${BOLD}Deleting secrets...${NC}"
for secret in "${SECRETS[@]}"; do
    aws secretsmanager delete-secret --secret-id "$secret" --region "$REGION" \
        --force-delete-without-recovery > /dev/null 2>&1 \
        && echo -e "${DIM}  Deleted ${secret}${NC}" \
        || echo -e "${DIM}  ${secret} not present${NC}"
done

echo ""
echo -e "${BOLD}Deleting log group...${NC}"
aws logs delete-log-group --log-group-name /ecs/agent-os --region "$REGION" 2> /dev/null \
    || echo -e "${DIM}Log group already gone${NC}"

echo ""
echo -e "${BOLD}Done.${NC} Verify nothing is left billing:"
echo -e "${DIM}  aws ecs describe-express-gateway-service --region ${REGION} --service-arn <arn>   # should fail${NC}"
echo -e "${DIM}  aws rds describe-db-instances --region ${REGION} --query 'DBInstances[].DBInstanceIdentifier'${NC}"
echo -e "${DIM}  aws elbv2 describe-load-balancers --region ${REGION} --query 'LoadBalancers[].LoadBalancerName'${NC}"
echo -e "${DIM}  aws secretsmanager list-secrets --region ${REGION} --query 'SecretList[].Name'${NC}"
echo ""
