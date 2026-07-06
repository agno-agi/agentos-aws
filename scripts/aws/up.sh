#!/bin/bash

############################################################################
#
#    Agno AWS Setup — ECS Express Mode (first-time provisioning)
#
#    Usage:     ./scripts/aws/up.sh
#    Redeploy:  ./scripts/aws/redeploy.sh
#    Sync env:  ./scripts/aws/env-sync.sh
#    Teardown:  ./scripts/aws/down.sh
#
#    Prerequisites:
#      - AWS CLI v2 recent enough to have the ECS Express Mode verbs
#        (`aws ecs create-express-gateway-service help` must work;
#        upgrade with e.g. `brew upgrade awscli` if it doesn't)
#      - Credentials configured (`aws sts get-caller-identity` succeeds)
#      - Docker running (the image is built locally and pushed to ECR)
#      - OPENAI_API_KEY set in environment (or .env / .env.production)
#
#    Provisions: ECR repo, RDS PostgreSQL 17 (private, pgvector via the
#    app's CREATE EXTENSION), Secrets Manager secrets, IAM roles, and one
#    ECS Express Mode service — which brings its own ALB, HTTPS URL,
#    autoscaling, and CloudWatch wiring. Sizing rides in the task
#    definition: 2 vCPU / 4 GB (family parity; the Express default is a
#    much smaller 0.25 vCPU / 512 MiB).
#
#    Overrides: AWS_REGION (default: us-east-1)
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${ORANGE}"
cat << 'BANNER'
     █████╗  ██████╗ ███╗   ██╗ ██████╗
    ██╔══██╗██╔════╝ ████╗  ██║██╔═══██╗
    ███████║██║  ███╗██╔██╗ ██║██║   ██║
    ██╔══██║██║   ██║██║╚██╗██║██║   ██║
    ██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝
    ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝
BANNER
echo -e "${NC}"

# Persist a resolved single-line value back into the env file so it stays a
# faithful record of the deploy (and env-sync.sh keeps managing it). Replaces
# an existing commented-or-uncommented `KEY=` line in place; appends if the key
# is absent. Rewrites via the original file (not `mv`) so the file keeps its
# inode + permissions. The `|` sed delimiter avoids clashing with URL slashes.
# No-op when the file is missing.
persist_env_var() {
    local key="$1" value="$2" file="$3" tmp
    [[ -z "$file" || ! -f "$file" ]] && return
    if grep -qE "^[#[:space:]]*${key}=" "$file"; then
        tmp="$(mktemp)"
        if sed -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$file" > "$tmp"; then
            cat "$tmp" > "$file"
        fi
        rm -f "$tmp"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# Persist a multi-line env value. Existing active KEY= blocks are removed before
# appending the new value; commented examples are left alone as documentation.
# Written quoted (KEY="...") — example.env's documented form, which every
# parser (docker compose env_file included) reads as one variable.
persist_multiline_env_var() {
    local key="$1" value="$2" file="$3" tmp line skipping=0 value_part
    [[ -z "$file" ]] && return
    if [[ ! -f "$file" ]]; then
        printf '%s="%s"\n' "$key" "$value" > "$file"
        return
    fi

    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$skipping" == 1 ]]; then
            [[ "$line" == *"-----END"* ]] && skipping=0
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            value_part="${line#*=}"
            if [[ "$value_part" == *"-----BEGIN"* && "$value_part" != *"-----END"* ]]; then
                skipping=1
            fi
            continue
        fi

        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Load env file — .env.production preferred, .env as fallback.
# Parsed line-by-line (not `source`d) so an unquoted multi-line PEM
# JWT_VERIFICATION_KEY isn't interpreted as shell. Mirrors the parser in
# env-sync.sh so both scripts read .env files identically. A function so
# the JWT pause below can re-read the file after the user edits it.
load_env_file() {
    local line current_key="" current_value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$current_key" ]]; then
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        fi

        if [[ -z "$current_key" ]]; then
            current_key="${line%%=*}"
            current_value="${line#*=}"
        else
            current_value="${current_value}
${line}"
        fi

        # Still inside a PEM block — keep accumulating lines.
        if [[ "$current_value" == *"-----BEGIN"* && "$current_value" != *"-----END"* ]]; then
            continue
        fi

        # Strip surrounding quotes if present
        current_value="${current_value#\"}"
        current_value="${current_value%\"}"
        current_value="${current_value#\'}"
        current_value="${current_value%\'}"

        export "${current_key}=${current_value}"

        current_key=""
        current_value=""
    done < "$1"
}

# shellcheck disable=SC2034 # helper reused verbatim from the agentos-railway scripts
capture_pasted_jwt_verification_key() {
    local first_line="$1" line pasted="$1"

    pasted="${pasted#export JWT_VERIFICATION_KEY=}"
    pasted="${pasted#JWT_VERIFICATION_KEY=}"
    [[ "$pasted" != *"-----BEGIN"* ]] && return 1

    while [[ "$pasted" != *"-----END"* ]]; do
        if ! IFS= read -r line; then
            break
        fi
        pasted="${pasted}
${line}"
    done

    [[ "$pasted" != *"-----BEGIN"* || "$pasted" != *"-----END"* ]] && return 1

    pasted="${pasted#\"}"
    pasted="${pasted%\"}"
    pasted="${pasted#\'}"
    pasted="${pasted%\'}"

    JWT_VERIFICATION_KEY="$pasted"
    export JWT_VERIFICATION_KEY
}

# Create-or-update a Secrets Manager secret and echo its ARN.
put_secret() {
    local name="$1" value="$2" arn
    arn="$(aws secretsmanager describe-secret --secret-id "$name" \
        --region "$REGION" --query ARN --output text 2> /dev/null || true)"
    if [[ -n "$arn" && "$arn" != "None" ]]; then
        aws secretsmanager put-secret-value --secret-id "$name" \
            --region "$REGION" --secret-string "$value" > /dev/null
    else
        arn="$(aws secretsmanager create-secret --name "$name" \
            --region "$REGION" --secret-string "$value" \
            --query ARN --output text)"
    fi
    printf '%s' "$arn"
}

# Escape a value for use in a sed replacement (we use | as the delimiter).
# Newlines become escaped newlines — sed rejects raw ones in the replacement.
sed_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//&/\\&}"
    v="${v//|/\\|}"
    v="${v//$'\n'/\\$'\n'}"
    printf '%s' "$v"
}

ENV_FILE=""
[[ -f .env.production ]] && ENV_FILE=".env.production"
[[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"

if [[ -n "$ENV_FILE" ]]; then
    load_env_file "$ENV_FILE"
    echo -e "${DIM}Loaded ${ENV_FILE}${NC}"
fi

# Preflight
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Install v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

if ! aws ecs create-express-gateway-service help &> /dev/null; then
    echo "Your AWS CLI ($(aws --version 2>&1)) predates ECS Express Mode."
    echo "Upgrade it (e.g. brew upgrade awscli) until this works:"
    echo "  aws ecs create-express-gateway-service help"
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    echo "AWS credentials not configured. Run: aws configure  (or set AWS_PROFILE)"
    exit 1
fi

if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
    echo "Docker not running. The image is built locally and pushed to ECR."
    exit 1
fi

if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "OPENAI_API_KEY not set. Add to .env (or .env.production) or export it."
    exit 1
fi

REGION="${AWS_REGION:-us-east-1}"
SERVICE_NAME="agent-os"
ECR_REPO="agentos"
RDS_INSTANCE="agentos-db"
RDS_SUBNET_GROUP="agentos-db-subnets"
RDS_SG_NAME="agentos-rds-sg"
STATE_FILE="tmp/agentos-aws.state"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

echo ""
echo -e "${BOLD}Account ${ACCOUNT_ID}, region ${REGION}${NC}"

# ---------------------------------------------------------------------------
# IAM roles (idempotent). Two roles:
#   - ecsTaskExecutionRole: lets the ECS agent pull from ECR, write logs,
#     and read our Secrets Manager secrets.
#   - ecsInfrastructureRoleForExpressServices: lets Express Mode create and
#     manage the ALB, target groups, SGs, and autoscaling on our behalf.
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Ensuring IAM roles...${NC}"

EXEC_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
INFRA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if ! aws iam get-role --role-name ecsTaskExecutionRole &> /dev/null; then
    aws iam create-role --role-name ecsTaskExecutionRole \
        --assume-role-policy-document "$EXEC_TRUST" > /dev/null
    echo -e "${DIM}  Created ecsTaskExecutionRole${NC}"
fi
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
# Two extras beyond the managed policy: read our secrets, and create the log
# group (task-def.json sets awslogs-create-group, which the managed policy's
# CreateLogStream/PutLogEvents grants do NOT cover).
aws iam put-role-policy --role-name ecsTaskExecutionRole \
    --policy-name agentos-task-execution-extras \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:agentos/*\"},{\"Effect\":\"Allow\",\"Action\":\"logs:CreateLogGroup\",\"Resource\":\"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/ecs/agent-os*\"}]}"
EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole"

if ! aws iam get-role --role-name ecsInfrastructureRoleForExpressServices &> /dev/null; then
    aws iam create-role --role-name ecsInfrastructureRoleForExpressServices \
        --assume-role-policy-document "$INFRA_TRUST" > /dev/null
    echo -e "${DIM}  Created ecsInfrastructureRoleForExpressServices${NC}"
fi
aws iam attach-role-policy --role-name ecsInfrastructureRoleForExpressServices \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices
INFRA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsInfrastructureRoleForExpressServices"

# ---------------------------------------------------------------------------
# ECR: repo + build + push
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Ensuring ECR repo + pushing image (linux/amd64)...${NC}"
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" &> /dev/null \
    || aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" > /dev/null
aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

# ---------------------------------------------------------------------------
# RDS PostgreSQL 17 — private (default VPC, no public access). pgvector is
# available on RDS PG; the app runs CREATE EXTENSION IF NOT EXISTS itself.
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Provisioning RDS PostgreSQL...${NC}"
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "No default VPC in ${REGION}. Create one (aws ec2 create-default-vpc) or adapt the script."
    exit 1
fi
VPC_CIDR="$(aws ec2 describe-vpcs --region "$REGION" \
    --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)"

RDS_SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters Name=group-name,Values="$RDS_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2> /dev/null || true)"
if [[ -z "$RDS_SG_ID" || "$RDS_SG_ID" == "None" ]]; then
    RDS_SG_ID="$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$RDS_SG_NAME" --description "AgentOS RDS access" \
        --vpc-id "$VPC_ID" --query GroupId --output text)"
    echo -e "${DIM}  Created security group ${RDS_SG_ID}${NC}"
fi

if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$RDS_SUBNET_GROUP" --region "$REGION" &> /dev/null; then
    # shellcheck disable=SC2207 # aws returns whitespace-separated ids
    SUBNET_IDS=($(aws ec2 describe-subnets --region "$REGION" \
        --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[].SubnetId' --output text))
    aws rds create-db-subnet-group --region "$REGION" \
        --db-subnet-group-name "$RDS_SUBNET_GROUP" \
        --db-subnet-group-description "AgentOS DB subnets (default VPC)" \
        --subnet-ids "${SUBNET_IDS[@]}" > /dev/null
    echo -e "${DIM}  Created DB subnet group${NC}"
fi

DB_PASSWORD="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)"
if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE" --region "$REGION" &> /dev/null; then
    echo -e "${DIM}  RDS instance ${RDS_INSTANCE} already exists — reusing (password unchanged)${NC}"
    DB_PASSWORD=""
else
    aws rds create-db-instance --region "$REGION" \
        --db-instance-identifier "$RDS_INSTANCE" \
        --db-instance-class db.t4g.micro \
        --engine postgres \
        --engine-version 17 \
        --allocated-storage 20 \
        --storage-type gp3 \
        --master-username ai \
        --master-user-password "$DB_PASSWORD" \
        --db-name ai \
        --no-publicly-accessible \
        --vpc-security-group-ids "$RDS_SG_ID" \
        --db-subnet-group-name "$RDS_SUBNET_GROUP" \
        --no-multi-az \
        --backup-retention-period 1 > /dev/null
    echo -e "${DIM}  Creating ${RDS_INSTANCE} (db.t4g.micro, 20GB gp3) — takes 5-10 minutes...${NC}"
fi
aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE" --region "$REGION"
DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE" \
    --region "$REGION" --query 'DBInstances[0].Endpoint.Address' --output text)"
echo -e "${DIM}  RDS endpoint: ${DB_HOST}${NC}"

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Storing secrets in Secrets Manager...${NC}"
OPENAI_SECRET_ARN="$(put_secret agentos/openai-api-key "$OPENAI_API_KEY")"
if [[ -n "$DB_PASSWORD" ]]; then
    DB_PASS_SECRET_ARN="$(put_secret agentos/db-pass "$DB_PASSWORD")"
else
    DB_PASS_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id agentos/db-pass \
        --region "$REGION" --query ARN --output text)"
fi
EXTRA_SECRETS=""
if [[ -n "$PARALLEL_API_KEY" ]]; then
    ARN="$(put_secret agentos/parallel-api-key "$PARALLEL_API_KEY")"
    EXTRA_SECRETS="${EXTRA_SECRETS}, { \"name\": \"PARALLEL_API_KEY\", \"valueFrom\": \"${ARN}\" }"
fi
if [[ -n "$SLACK_BOT_TOKEN" ]]; then
    ARN="$(put_secret agentos/slack-bot-token "$SLACK_BOT_TOKEN")"
    EXTRA_SECRETS="${EXTRA_SECRETS}, { \"name\": \"SLACK_BOT_TOKEN\", \"valueFrom\": \"${ARN}\" }"
fi
if [[ -n "$SLACK_SIGNING_SECRET" ]]; then
    ARN="$(put_secret agentos/slack-signing-secret "$SLACK_SIGNING_SECRET")"
    EXTRA_SECRETS="${EXTRA_SECRETS}, { \"name\": \"SLACK_SIGNING_SECRET\", \"valueFrom\": \"${ARN}\" }"
fi
echo -e "${DIM}Secrets stored under agentos/*${NC}"

# ---------------------------------------------------------------------------
# Task definition — rendered from scripts/aws/task-def.json.
# The URL is predictable for Express services (https://<name>.ecs.<region>.on.aws),
# so AGENTOS_URL is set before the service exists; the describe call after
# create verifies it and rolls a correcting revision only if reality differs.
# ---------------------------------------------------------------------------
PREDICTED_URL="https://${SERVICE_NAME}.ecs.${REGION}.on.aws"
AGENTOS_URL_VALUE="${AGENTOS_URL:-$PREDICTED_URL}"

EXTRA_ENV=""
[[ -n "$RUNTIME_ENV" ]] && EXTRA_ENV="${EXTRA_ENV}, { \"name\": \"RUNTIME_ENV\", \"value\": \"${RUNTIME_ENV}\" }"

render_task_def() {
    local out="$1"
    sed -e "s|__IMAGE__|$(sed_escape "$IMAGE")|" \
        -e "s|__EXECUTION_ROLE_ARN__|$(sed_escape "$EXECUTION_ROLE_ARN")|" \
        -e "s|__REGION__|$(sed_escape "$REGION")|" \
        -e "s|__DB_HOST__|$(sed_escape "$DB_HOST")|" \
        -e "s|__AGENTOS_URL__|$(sed_escape "$AGENTOS_URL_VALUE")|" \
        -e "s|__OPENAI_SECRET_ARN__|$(sed_escape "$OPENAI_SECRET_ARN")|" \
        -e "s|__DB_PASS_SECRET_ARN__|$(sed_escape "$DB_PASS_SECRET_ARN")|" \
        -e "s|__EXTRA_ENV__|$(sed_escape "$EXTRA_ENV")|" \
        -e "s|__EXTRA_SECRETS__|$(sed_escape "$EXTRA_SECRETS")|" \
        scripts/aws/task-def.json > "$out"
}

echo ""
echo -e "${BOLD}Registering task definition (2 vCPU / 4 GB)...${NC}"
mkdir -p tmp
render_task_def tmp/task-def.rendered.json
TASK_DEF_ARN="$(aws ecs register-task-definition --region "$REGION" \
    --cli-input-json file://tmp/task-def.rendered.json \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
echo -e "${DIM}  ${TASK_DEF_ARN}${NC}"

# ---------------------------------------------------------------------------
# Express Mode service. One call provisions Fargate service, ALB + HTTPS,
# target groups, SGs, autoscaling, logs/alarms, and the public URL.
# /health is served unauthenticated by AgentOS even in prd (verified), so
# ALB health checks pass with JWT auth on. Retries cover the documented
# IAM eventual-consistency window after fresh role creation.
# ---------------------------------------------------------------------------
# Re-runs against an existing deployment skip creation and roll the freshly
# registered revision instead. ARN resolution mirrors down.sh: state file
# first (machine-local), then the env files up.sh persists it into.
EXISTING_SERVICE_ARN=""
[[ -f "$STATE_FILE" ]] && EXISTING_SERVICE_ARN="$(sed -nE 's/^SERVICE_ARN=(.*)$/\1/p' "$STATE_FILE" | head -1)"
if [[ -z "$EXISTING_SERVICE_ARN" ]]; then
    for f in .env.production .env; do
        [[ -f "$f" ]] && EXISTING_SERVICE_ARN="$(sed -nE 's/^SERVICE_ARN=(.*)$/\1/p' "$f" | head -1)" && [[ -n "$EXISTING_SERVICE_ARN" ]] && break
    done
fi
if [[ -n "$EXISTING_SERVICE_ARN" ]]; then
    EXISTING_STATUS="$(aws ecs describe-express-gateway-service --region "$REGION" \
        --service-arn "$EXISTING_SERVICE_ARN" \
        --query 'service.status.statusCode' --output text 2> /dev/null || true)"
    [[ "$EXISTING_STATUS" != "ACTIVE" ]] && EXISTING_SERVICE_ARN=""
fi

echo ""
if [[ -n "$EXISTING_SERVICE_ARN" ]]; then
    echo -e "${BOLD}Express Mode service already exists and is ACTIVE — updating instead of creating...${NC}"
    SERVICE_ARN="$EXISTING_SERVICE_ARN"
    aws ecs update-express-gateway-service --region "$REGION" \
        --service-arn "$SERVICE_ARN" \
        --task-definition-arn "$TASK_DEF_ARN" > /dev/null
else
    echo -e "${BOLD}Creating Express Mode service...${NC}"
    SERVICE_ARN=""
    for attempt in 1 2 3 4 5 6; do
        # min 1 / max 1 pinned: min 1 keeps the in-process scheduler alive;
        # max 1 because scale-out would run N schedulers double-firing every
        # cron (same reason the Fly sibling deploys --ha=false).
        if CREATE_OUT="$(aws ecs create-express-gateway-service --region "$REGION" \
            --service-name "$SERVICE_NAME" \
            --task-definition-arn "$TASK_DEF_ARN" \
            --infrastructure-role-arn "$INFRA_ROLE_ARN" \
            --health-check-path /health \
            --scaling-target '{"minTaskCount": 1, "maxTaskCount": 1}' \
            --query 'service.serviceArn' --output text 2> tmp/express-create.err)"; then
            SERVICE_ARN="$CREATE_OUT"
            break
        fi
        if grep -qiE 'assume|not authorized|invalid.*role' tmp/express-create.err && [[ $attempt -lt 6 ]]; then
            echo -e "${DIM}  IAM roles still propagating (attempt ${attempt}/6) — retrying in 10s...${NC}"
            sleep 10
        else
            cat tmp/express-create.err
            exit 1
        fi
    done
    rm -f tmp/express-create.err
fi
echo -e "${DIM}  ${SERVICE_ARN}${NC}"
{ printf 'SERVICE_ARN=%s\n' "$SERVICE_ARN"; printf 'REGION=%s\n' "$REGION"; } > "$STATE_FILE"
# Also record the ARN in the env file: tmp/ is gitignored and machine-local,
# and down.sh needs the ARN to delete the most expensive resource.
persist_env_var SERVICE_ARN "$SERVICE_ARN" "$ENV_FILE"

echo -e "${DIM}Waiting for the service URL...${NC}"
APP_URL=""
for _ in $(seq 1 60); do
    APP_URL="$(aws ecs describe-express-gateway-service --region "$REGION" \
        --service-arn "$SERVICE_ARN" \
        --query 'service.activeConfigurations[0].ingressPaths[0].endpoint' \
        --output text 2> /dev/null || true)"
    [[ -n "$APP_URL" && "$APP_URL" != "None" ]] && break
    sleep 10
done
[[ "$APP_URL" == "None" ]] && APP_URL=""
[[ "$APP_URL" != https://* && -n "$APP_URL" ]] && APP_URL="https://${APP_URL}"

# ---------------------------------------------------------------------------
# Lock down RDS: allow 5432 only from inside the VPC (the Express service's
# tasks). If the describe output exposes the service SG, narrow to it.
# ---------------------------------------------------------------------------
SERVICE_SG="$(aws ecs describe-express-gateway-service --region "$REGION" \
    --service-arn "$SERVICE_ARN" \
    --query 'service.activeConfigurations[0].networkConfiguration.securityGroups[0]' \
    --output text 2> /dev/null || true)"
if [[ -n "$SERVICE_SG" && "$SERVICE_SG" == sg-* ]]; then
    aws ec2 authorize-security-group-ingress --region "$REGION" \
        --group-id "$RDS_SG_ID" --protocol tcp --port 5432 \
        --source-group "$SERVICE_SG" 2> /dev/null \
        || echo -e "${DIM}  RDS ingress from service SG already present${NC}"
    echo -e "${DIM}  RDS ingress: 5432 from ${SERVICE_SG}${NC}"
else
    aws ec2 authorize-security-group-ingress --region "$REGION" \
        --group-id "$RDS_SG_ID" --protocol tcp --port 5432 \
        --cidr "$VPC_CIDR" 2> /dev/null \
        || echo -e "${DIM}  RDS ingress from VPC CIDR already present${NC}"
    echo -e "${DIM}  RDS ingress: 5432 from ${VPC_CIDR} (service SG not exposed by describe;${NC}"
    echo -e "${DIM}  still private — the DB has no public address)${NC}"
fi

AUTH_REQUIRES_JWT=1
[[ "${RUNTIME_ENV:-prd}" == "dev" ]] && AUTH_REQUIRES_JWT=""

# JWT auth is on in prd and the app refuses to serve without either a PEM
# verification key or a JWKS file. Now that the URL exists, the user can
# mint the key against it; the PEM lands in Secrets Manager and rides into
# the correcting revision below.
if [[ -n "$AUTH_REQUIRES_JWT" && -z "$JWT_VERIFICATION_KEY" && -z "$JWT_JWKS_FILE" && -t 0 ]]; then
    echo ""
    echo -e "${BOLD}JWT_VERIFICATION_KEY not set${NC} — AgentOS won't serve production traffic without auth."
    echo -e "  1. Open ${BOLD}https://os.agno.com${NC} -> Connect OS -> Live -> enter ${APP_URL:-your service URL}"
    echo -e "  2. Name it ${BOLD}Live AgentOS${NC}"
    echo -e "  3. Note: Live AgentOS Connections are a paid feature; use ${BOLD}PLATFORM30${NC} to get 1 month off"
    echo -e "  4. Go to Settings -> OS & Security -> turn ${BOLD}Token-Based Authorization (JWT)${NC} on"
    echo -e "  5. Copy the public key"
    echo -e "  6. Paste the full PEM block at the prompt below, or save it in ${ENV_FILE:-.env.production}"
    echo -e "     Or set JWT_JWKS_FILE if you mount a JWKS file in the image."
    echo ""
    echo -e "  Paste JWT_VERIFICATION_KEY now, or press Enter after saving it:"
    JWT_INPUT=""
    IFS= read -r JWT_INPUT || true
    if [[ -n "$JWT_INPUT" ]]; then
        if capture_pasted_jwt_verification_key "$JWT_INPUT"; then
            ENV_FILE="${ENV_FILE:-.env.production}"
            persist_multiline_env_var JWT_VERIFICATION_KEY "$JWT_VERIFICATION_KEY" "$ENV_FILE"
            echo -e "${DIM}  Saved JWT_VERIFICATION_KEY to ${ENV_FILE}${NC}"
        else
            echo -e "${BOLD}Warning:${NC} couldn't parse the pasted JWT_VERIFICATION_KEY."
            echo -e "${DIM}  Save it to ${ENV_FILE:-.env.production} and run ./scripts/aws/env-sync.sh if auth is still missing.${NC}"
        fi
    else
        [[ -f .env.production ]] && ENV_FILE=".env.production"
        [[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"
    fi
    [[ -n "$ENV_FILE" ]] && load_env_file "$ENV_FILE"
fi

NEEDS_REVISION=""
if [[ -n "$JWT_VERIFICATION_KEY" ]]; then
    echo ""
    echo -e "${DIM}Storing JWT_VERIFICATION_KEY in Secrets Manager${NC}"
    JWT_SECRET_ARN="$(put_secret agentos/jwt-verification-key "$JWT_VERIFICATION_KEY")"
    EXTRA_SECRETS="${EXTRA_SECRETS}, { \"name\": \"JWT_VERIFICATION_KEY\", \"valueFrom\": \"${JWT_SECRET_ARN}\" }"
    NEEDS_REVISION=1
elif [[ -n "$AUTH_REQUIRES_JWT" && -z "$JWT_JWKS_FILE" ]]; then
    echo ""
    echo -e "${DIM}Deployed without JWT auth config — the app will refuse traffic until${NC}"
    echo -e "${DIM}you add JWT_VERIFICATION_KEY or JWT_JWKS_FILE to ${ENV_FILE:-.env.production} and run ./scripts/aws/env-sync.sh.${NC}"
fi

if [[ -n "$APP_URL" && "$APP_URL" != "$AGENTOS_URL_VALUE" ]]; then
    echo -e "${DIM}Actual URL (${APP_URL}) differs from predicted (${AGENTOS_URL_VALUE}) — rolling a fix${NC}"
    AGENTOS_URL_VALUE="$APP_URL"
    NEEDS_REVISION=1
fi

if [[ -n "$NEEDS_REVISION" ]]; then
    echo ""
    echo -e "${BOLD}Rolling task definition revision (URL/JWT)...${NC}"
    render_task_def tmp/task-def.rendered.json
    TASK_DEF_ARN="$(aws ecs register-task-definition --region "$REGION" \
        --cli-input-json file://tmp/task-def.rendered.json \
        --query 'taskDefinition.taskDefinitionArn' --output text)"
    aws ecs update-express-gateway-service --region "$REGION" \
        --service-arn "$SERVICE_ARN" \
        --task-definition-arn "$TASK_DEF_ARN" > /dev/null
    echo -e "${DIM}  ${TASK_DEF_ARN}${NC}"
fi
rm -f tmp/task-def.rendered.json

[[ -n "$APP_URL" ]] && persist_env_var AGENTOS_URL "$APP_URL" "$ENV_FILE"

echo ""
echo -e "${BOLD}Done.${NC} The service is rolling out — give it a few minutes."
[[ -n "$APP_URL" ]] && echo -e "${DIM}URL:            ${APP_URL}${NC}"
echo -e "${DIM}Status:         aws ecs describe-express-gateway-service --region ${REGION} --service-arn ${SERVICE_ARN}${NC}"
echo -e "${DIM}Logs:           aws logs tail /ecs/agent-os --region ${REGION} --follow${NC}"
echo -e "${DIM}Sync env vars:  ./scripts/aws/env-sync.sh  (defaults to .env.production)${NC}"
echo -e "${DIM}Teardown:       ./scripts/aws/down.sh  (AWS bills idle resources — tear down what you don't use)${NC}"
echo -e "${DIM}Cost:           ~\$70/mo Fargate (2 vCPU/4GB x86) + ~\$17-25/mo ALB (shared across up${NC}"
echo -e "${DIM}                to 25 Express services) + ~\$14/mo RDS db.t4g.micro ≈ \$100-110/mo.${NC}"
echo ""
