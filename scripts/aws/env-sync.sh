#!/bin/bash

############################################################################
#
#    Agno AWS Environment Sync — ECS Express Mode
#
#    Usage:
#      ./scripts/aws/env-sync.sh             # syncs .env.production
#      ./scripts/aws/env-sync.sh .env        # syncs .env instead
#
#    Reads the file, pushes secret-shaped keys (API keys, DB_PASS,
#    JWT_VERIFICATION_KEY, Slack credentials, MCP OAuth secrets) to
#    Secrets Manager, renders a fresh task-definition revision carrying
#    everything else as plain env vars, and rolls the Express service to
#    it (one rolling deployment). Multi-line values (PEM-formatted
#    JWT_VERIFICATION_KEY) are handled.
#
#    DB_HOST/DB_PORT/DB_USER/DB_DATABASE are computed from the RDS instance
#    this template provisioned and are skipped if present in the env file —
#    point db/url.py somewhere else by editing scripts/aws/task-def.json.
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

# Default mirrors up.sh: prefer .env.production, fall back to .env.
ENV_FILE="$1"
if [[ -z "$ENV_FILE" ]]; then
    if [[ -f .env.production ]]; then ENV_FILE=".env.production"
    elif [[ -f .env ]]; then ENV_FILE=".env"
    else ENV_FILE=".env.production"; fi
fi
SERVICE_NAME="agent-os"
ECR_REPO="agentos"
RDS_INSTANCE="agentos-db"
STATE_FILE="tmp/agentos-aws.state"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "File not found: $ENV_FILE"
    echo "Usage: $0 [path/to/env] (default: .env.production)"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Install v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Region precedence: explicit AWS_REGION > the region up.sh recorded in the
# state file > default. Mirrors down.sh so a fresh shell rolls the service
# in the region it was deployed to.
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
if [[ -z "$SERVICE_ARN" ]]; then
    echo "No service ARN found in ${STATE_FILE} or SERVICE_ARN= in .env.production/.env."
    echo "Run ./scripts/aws/up.sh first, or write the ARN of the Express service into the state file:"
    echo "  printf 'SERVICE_ARN=arn:aws:ecs:...' > ${STATE_FILE}"
    exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"
EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole"
DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE" \
    --region "$REGION" --query 'DBInstances[0].Endpoint.Address' --output text)"

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

# Keys that must live in Secrets Manager rather than plain task-def env vars.
is_secret_key() {
    case "$1" in
        OPENAI_API_KEY|DB_PASS|JWT_VERIFICATION_KEY|PARALLEL_API_KEY|SLACK_BOT_TOKEN|SLACK_SIGNING_SECRET|MCP_CONNECT_SECRET|AGENTOS_MCP_SIGNING_KEY) return 0 ;;
        *) return 1 ;;
    esac
}

# Secrets Manager names are agentos/<lowercase-dashed key>.
secret_name_for() {
    printf 'agentos/%s' "$(printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-')"
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

# JSON-escape the characters that can appear in env values, including the
# newlines/control chars of multi-line values.
json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\r'/\\r}"
    v="${v//$'\t'/\\t}"
    printf '%s' "$v"
}

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Syncing env vars${NC}"
echo ""
echo -e "${DIM}> ${ENV_FILE} -> Express service ${SERVICE_NAME}${NC}"
echo ""

# Parse the env file, treating PEM blocks (and other multiline values)
# as a single variable. OPENAI_API_KEY and DB_PASS keep their template slots;
# everything else accumulates into the rendered extras.
AGENTOS_URL_VALUE=""
EXTRA_ENV=""
EXTRA_SECRETS=""
OPENAI_FROM_FILE=""
DB_PASS_SYNCED=""
count=0
current_key=""
current_value=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments (only when not inside a multiline value)
    if [[ -z "$current_key" ]]; then
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    fi

    if [[ -z "$current_key" ]]; then
        # Start of a new variable
        current_key="${line%%=*}"
        current_value="${line#*=}"
    else
        # Continuation of a multiline value
        current_value="${current_value}
${line}"
    fi

    # Check if the value is complete (not in the middle of a PEM block)
    if [[ "$current_value" == *"-----BEGIN"* && "$current_value" != *"-----END"* ]]; then
        continue
    fi

    # Strip surrounding quotes if present
    current_value="${current_value#\"}"
    current_value="${current_value%\"}"
    current_value="${current_value#\'}"
    current_value="${current_value%\'}"

    case "$current_key" in
        DB_HOST|DB_PORT|DB_USER|DB_DATABASE|DB_DRIVER)
            echo -e "${DIM}  Skipping ${current_key} (computed from the provisioned RDS instance)${NC}"
            ;;
        SERVICE_ARN)
            echo -e "${DIM}  Skipping SERVICE_ARN (deploy metadata, not a container env var)${NC}"
            ;;
        AGENTOS_URL)
            AGENTOS_URL_VALUE="$current_value"
            echo -e "${DIM}  Env var AGENTOS_URL${NC}"
            count=$((count + 1))
            ;;
        OPENAI_API_KEY)
            put_secret agentos/openai-api-key "$current_value" > /dev/null
            OPENAI_FROM_FILE=1
            echo -e "${DIM}  Secret OPENAI_API_KEY -> agentos/openai-api-key${NC}"
            count=$((count + 1))
            ;;
        DB_PASS)
            put_secret agentos/db-pass "$current_value" > /dev/null
            DB_PASS_SYNCED=1
            echo -e "${DIM}  Secret DB_PASS -> agentos/db-pass${NC}"
            count=$((count + 1))
            ;;
        *)
            if is_secret_key "$current_key"; then
                secret_name="$(secret_name_for "$current_key")"
                ARN="$(put_secret "$secret_name" "$current_value")"
                EXTRA_SECRETS="${EXTRA_SECRETS}, { \"name\": \"${current_key}\", \"valueFrom\": \"${ARN}\" }"
                echo -e "${DIM}  Secret ${current_key} -> ${secret_name}${NC}"
            else
                EXTRA_ENV="${EXTRA_ENV}, { \"name\": \"${current_key}\", \"value\": \"$(json_escape "$current_value")\" }"
                echo -e "${DIM}  Env var ${current_key}${NC}"
            fi
            count=$((count + 1))
            ;;
    esac

    current_key=""
    current_value=""
done < "$ENV_FILE"

if [[ $count -eq 0 ]]; then
    echo "Nothing to sync."
    exit 0
fi

[[ -z "$OPENAI_FROM_FILE" ]] && echo -e "${DIM}  OPENAI_API_KEY not in ${ENV_FILE} — keeping the stored secret${NC}"
[[ -z "$DB_PASS_SYNCED" ]] && echo -e "${DIM}  DB_PASS not in ${ENV_FILE} — keeping the stored secret${NC}"

OPENAI_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id agentos/openai-api-key \
    --region "$REGION" --query ARN --output text)"
DB_PASS_SECRET_ARN="$(aws secretsmanager describe-secret --secret-id agentos/db-pass \
    --region "$REGION" --query ARN --output text)"

if [[ -z "$AGENTOS_URL_VALUE" ]]; then
    AGENTOS_URL_VALUE="$(aws ecs describe-express-gateway-service --region "$REGION" \
        --service-arn "$SERVICE_ARN" \
        --query 'service.activeConfigurations[0].ingressPaths[0].endpoint' \
        --output text 2> /dev/null || true)"
    [[ "$AGENTOS_URL_VALUE" == "None" ]] && AGENTOS_URL_VALUE=""
    [[ "$AGENTOS_URL_VALUE" != https://* && -n "$AGENTOS_URL_VALUE" ]] \
        && AGENTOS_URL_VALUE="https://${AGENTOS_URL_VALUE}"
    if [[ -z "$AGENTOS_URL_VALUE" ]]; then
        echo -e "${BOLD}Warning:${NC} couldn't resolve the service URL — AGENTOS_URL stays unset"
        echo -e "${DIM}in this revision, and scheduled jobs won't fire until it is set.${NC}"
    fi
fi

echo ""
echo -e "${BOLD}Registering task definition revision...${NC}"
mkdir -p tmp
sed -e "s|__IMAGE__|$(sed_escape "$IMAGE")|" \
    -e "s|__EXECUTION_ROLE_ARN__|$(sed_escape "$EXECUTION_ROLE_ARN")|" \
    -e "s|__REGION__|$(sed_escape "$REGION")|" \
    -e "s|__DB_HOST__|$(sed_escape "$DB_HOST")|" \
    -e "s|__AGENTOS_URL__|$(sed_escape "$AGENTOS_URL_VALUE")|" \
    -e "s|__OPENAI_SECRET_ARN__|$(sed_escape "$OPENAI_SECRET_ARN")|" \
    -e "s|__DB_PASS_SECRET_ARN__|$(sed_escape "$DB_PASS_SECRET_ARN")|" \
    -e "s|__EXTRA_ENV__|$(sed_escape "$EXTRA_ENV")|" \
    -e "s|__EXTRA_SECRETS__|$(sed_escape "$EXTRA_SECRETS")|" \
    scripts/aws/task-def.json > tmp/task-def.rendered.json
TASK_DEF_ARN="$(aws ecs register-task-definition --region "$REGION" \
    --cli-input-json file://tmp/task-def.rendered.json \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
rm -f tmp/task-def.rendered.json
echo -e "${DIM}  ${TASK_DEF_ARN}${NC}"

echo ""
echo -e "${BOLD}Rolling the service...${NC}"
aws ecs update-express-gateway-service --region "$REGION" \
    --service-arn "$SERVICE_ARN" \
    --task-definition-arn "$TASK_DEF_ARN" > /dev/null

echo ""
echo -e "${BOLD}Done.${NC} Synced ${count} variable(s) — Express is rolling a new deployment."
echo -e "${DIM}Status: aws ecs describe-express-gateway-service --region ${REGION} --service-arn ${SERVICE_ARN}${NC}"
echo ""
