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
DIM='\033[2m'
BOLD='\033[1m'
RED='\033[31m'
NC='\033[0m'

ECR_REPO="agentos"
RDS_INSTANCE="agentos-db"
RDS_SUBNET_GROUP="agentos-db-subnets"
RDS_SG_NAME="agentos-rds-sg"
STATE_FILE="tmp/agentos-aws.state"
SECRETS=(agentos/openai-api-key agentos/db-pass agentos/jwt-verification-key agentos/parallel-api-key agentos/slack-bot-token agentos/slack-signing-secret)

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
echo -e "${BOLD}This deletes from region ${REGION}:${NC}"
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

if [[ -n "$SERVICE_ARN" ]]; then
    echo ""
    echo -e "${BOLD}Deleting Express service (removes ALB wiring, SGs, autoscaling)...${NC}"
    aws ecs delete-express-gateway-service --region "$REGION" \
        --service-arn "$SERVICE_ARN" > /dev/null \
        || echo -e "${DIM}Service already gone or delete failed — verify below${NC}"
    echo -e "${DIM}Waiting for the service to drain...${NC}"
    STATUS="ACTIVE"
    for _ in $(seq 1 60); do
        STATUS="$(aws ecs describe-express-gateway-service --region "$REGION" \
            --service-arn "$SERVICE_ARN" \
            --query 'service.status.statusCode' --output text 2> /dev/null || echo GONE)"
        # Terminal states: describe fails once the service is fully removed
        # (GONE), and INACTIVE is the API's deleted state.
        [[ "$STATUS" == "GONE" || "$STATUS" == "None" || "$STATUS" == "INACTIVE" ]] && break
        sleep 10
    done
    if [[ "$STATUS" == "GONE" || "$STATUS" == "None" || "$STATUS" == "INACTIVE" ]]; then
        rm -f "$STATE_FILE"
    else
        echo -e "${BOLD}Service still ${STATUS} after 10 minutes${NC} — keeping ${STATE_FILE} so you can retry."
        echo -e "${DIM}  ARN: ${SERVICE_ARN}${NC}"
        exit 1
    fi
else
    echo -e "${DIM}No service ARN recorded — if a service exists, delete it with:${NC}"
    echo -e "${DIM}  aws ecs delete-express-gateway-service --region ${REGION} --service-arn <arn>${NC}"
fi

echo ""
echo -e "${BOLD}Deleting RDS instance (takes a few minutes)...${NC}"
aws rds delete-db-instance --region "$REGION" \
    --db-instance-identifier "$RDS_INSTANCE" \
    --skip-final-snapshot --delete-automated-backups > /dev/null \
    || echo -e "${DIM}Instance already gone${NC}"
aws rds wait db-instance-deleted --db-instance-identifier "$RDS_INSTANCE" --region "$REGION" \
    || true

aws rds delete-db-subnet-group --db-subnet-group-name "$RDS_SUBNET_GROUP" --region "$REGION" 2> /dev/null \
    || echo -e "${DIM}Subnet group already gone${NC}"

RDS_SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters Name=group-name,Values="$RDS_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2> /dev/null || true)"
if [[ -n "$RDS_SG_ID" && "$RDS_SG_ID" != "None" ]]; then
    aws ec2 delete-security-group --region "$REGION" --group-id "$RDS_SG_ID" 2> /dev/null \
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
