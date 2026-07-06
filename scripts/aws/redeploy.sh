#!/bin/bash

############################################################################
#
#    Agno AWS Redeploy — ECS Express Mode
#
#    Usage: ./scripts/aws/redeploy.sh [env-file]
#
#    Rebuilds the image, pushes it to ECR, then delegates to env-sync.sh,
#    which registers a fresh task-definition revision and rolls the Express
#    service — new tasks pull the new :latest image. Run ./scripts/aws/up.sh
#    first for initial provisioning.
#
#    Overrides: AWS_REGION (default: us-east-1)
#
############################################################################

set -e

# Colors
BOLD='\033[1m'
NC='\033[0m'

ECR_REPO="agentos"
STATE_FILE="tmp/agentos-aws.state"

# Preflight
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Install v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
    echo "Docker not running. The image is built locally and pushed to ECR."
    exit 1
fi

# Service ARN: state file first (machine-local), then the env files up.sh
# persists it into (survives fresh clones and cleaned tmp/). env-sync.sh
# resolves it the same way — this preflight just fails fast before a build.
SERVICE_ARN=""
[[ -f "$STATE_FILE" ]] && SERVICE_ARN="$(sed -nE 's/^SERVICE_ARN=(.*)$/\1/p' "$STATE_FILE" | head -1)"
if [[ -z "$SERVICE_ARN" ]]; then
    for f in .env.production .env; do
        [[ -f "$f" ]] && SERVICE_ARN="$(sed -nE 's/^SERVICE_ARN=(.*)$/\1/p' "$f" | head -1)" && [[ -n "$SERVICE_ARN" ]] && break
    done
fi
if [[ -z "$SERVICE_ARN" ]]; then
    echo "No service state in ${STATE_FILE} or SERVICE_ARN= in .env.production/.env. Run ./scripts/aws/up.sh first."
    exit 1
fi

# Region precedence: explicit AWS_REGION > the region up.sh recorded in the
# state file > default. Mirrors down.sh so the image lands in the ECR repo
# the service actually pulls from.
REGION="$AWS_REGION"
[[ -z "$REGION" && -f "$STATE_FILE" ]] && REGION="$(sed -nE 's/^REGION=(.*)$/\1/p' "$STATE_FILE" | head -1)"
REGION="${REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

echo ""
echo -e "${BOLD}Building and pushing image (linux/amd64)...${NC}"
echo ""
aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

echo ""
echo -e "${BOLD}Rolling the service to the new build...${NC}"
"$(dirname "$0")/env-sync.sh" "$@"
