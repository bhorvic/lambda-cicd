#!/bin/bash
# scripts/deploy.sh - Simulates a full CI/CD pipeline for Lambda deployment
#
# Usage:
#   ./scripts/deploy.sh
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Copy config/config.env.example to config/config.env and fill in values
#   - S3 bucket will be created automatically if it doesn't exist

set -Eeuo pipefail

# ── Helpers ────────────────────────────────────────────────────────────────────
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $1"
        exit 1
    fi
}

wait_for_lambda_ready() {
    local function_name="$1"
    local attempts=30
    local delay=2
    local state=""
    local last_update_status=""

    echo "Waiting for Lambda to become ready..."

    for ((i=1; i<=attempts; i++)); do
        state=$(aws lambda get-function-configuration \
            --function-name "${function_name}" \
            --region "${REGION}" \
            --query 'State' \
            --output text 2>/dev/null || true)

        last_update_status=$(aws lambda get-function-configuration \
            --function-name "${function_name}" \
            --region "${REGION}" \
            --query 'LastUpdateStatus' \
            --output text 2>/dev/null || true)

        if [ "${state}" = "Active" ] && [ "${last_update_status}" = "Successful" ]; then
            echo "✓ Lambda is ready."
            return 0
        fi

        if [ "${last_update_status}" = "Failed" ]; then
            echo "ERROR: Lambda update failed."
            aws lambda get-function-configuration \
                --function-name "${function_name}" \
                --region "${REGION}" \
                --query '{State: State, LastUpdateStatus: LastUpdateStatus, LastUpdateStatusReason: LastUpdateStatusReason}'
            exit 1
        fi

        sleep "${delay}"
    done

    echo "ERROR: Timed out waiting for Lambda to become ready."
    exit 1
}

cleanup_build() {
    if [ -n "${BUILD_DIR:-}" ] && [ -d "${BUILD_DIR}" ]; then
        rm -rf "${BUILD_DIR}"
    fi
}

trap cleanup_build EXIT

# ── Config ─────────────────────────────────────────────────────────────────────
require_cmd aws
require_cmd python3
require_cmd zip

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: config/config.env not found."
    echo "Copy config/config.env.example to config/config.env and fill in your values."
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${REGION:?config.env must define REGION}"
: "${FUNCTION_NAME:?config.env must define FUNCTION_NAME}"
: "${ROLE_NAME:=lambda-basic-execution-role}"

# BUCKET_NAME is optional — if not set, auto-generate one from the account ID
BUCKET_OWNER_MANAGED=false
if [ -z "${BUCKET_NAME:-}" ]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
    BUCKET_NAME="${FUNCTION_NAME}-deploy-${ACCOUNT_ID}"
    BUCKET_OWNER_MANAGED=true
    echo "No BUCKET_NAME set — will use auto-generated bucket: ${BUCKET_NAME}"
fi

VERSION=$(date +%Y%m%d-%H%M%S)
SRC_DIR="${REPO_ROOT}/src"
TESTS_DIR="${REPO_ROOT}/tests"
BUILD_DIR="${REPO_ROOT}/.build"
ZIP_NAME="lambda-${VERSION}.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"

mkdir -p "${BUILD_DIR}"

echo "=========================================="
echo "CI/CD Pipeline Started"
echo "Function : ${FUNCTION_NAME}"
echo "Region   : ${REGION}"
echo "Version  : ${VERSION}"
echo "=========================================="

# ── Step 1: Tests ──────────────────────────────────────────────────────────────
echo ""
echo "[BUILD] Step 1: Running tests..."
python3 "${TESTS_DIR}/test_lambda.py"

# ── Step 2: Package ────────────────────────────────────────────────────────────
echo ""
echo "[BUILD] Step 2: Packaging application..."
(
    cd "${SRC_DIR}"
    zip -q "${ZIP_PATH}" lambda_function.py
)
echo "Created ${ZIP_PATH}"

# ── Step 3: Ensure S3 bucket exists ───────────────────────────────────────────
echo ""
echo "[DEPLOY] Step 3: Checking S3 bucket..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
    echo "Bucket ${BUCKET_NAME} already exists."
else
    echo "Bucket ${BUCKET_NAME} not found — creating it..."

    # us-east-1 does not accept a LocationConstraint — all other regions require it
    if [ "${REGION}" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${REGION}"
    else
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${REGION}" \
            --create-bucket-configuration LocationConstraint="${REGION}"
    fi

    # Block all public access
    aws s3api put-public-access-block \
        --bucket "${BUCKET_NAME}" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    echo "✓ Bucket ${BUCKET_NAME} created and public access blocked."

    # If the bucket was auto-generated (no BUCKET_NAME in config), record it
    # so cleanup.sh knows it's safe to delete
    if [ "${BUCKET_OWNER_MANAGED}" = true ]; then
        echo "${BUCKET_NAME}" > "${REPO_ROOT}/.auto_created_bucket"
        echo "  (recorded in .auto_created_bucket for cleanup)"
    fi
fi

# ── Step 4: Upload to S3 ───────────────────────────────────────────────────────
echo ""
echo "[DEPLOY] Step 4: Uploading to S3..."
aws s3 cp "${ZIP_PATH}" "s3://${BUCKET_NAME}/lambda-builds/${ZIP_NAME}"

# ── Step 5: Create or update function ─────────────────────────────────────────
echo ""
echo "[DEPLOY] Step 5: Checking if Lambda function exists..."
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${REGION}" >/dev/null 2>&1; then
    echo "Function exists — updating code..."
    aws lambda update-function-code \
        --function-name "${FUNCTION_NAME}" \
        --s3-bucket "${BUCKET_NAME}" \
        --s3-key "lambda-builds/${ZIP_NAME}" \
        --region "${REGION}" >/dev/null
else
    echo "Function not found — creating it..."

    if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
        ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
    else
        echo "Creating IAM role ${ROLE_NAME}..."
        TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)
        ROLE_ARN=$(aws iam create-role \
            --role-name "${ROLE_NAME}" \
            --assume-role-policy-document "${TRUST_POLICY}" \
            --query 'Role.Arn' \
            --output text)

        aws iam attach-role-policy \
            --role-name "${ROLE_NAME}" \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

        echo "Waiting for IAM role to propagate..."
        sleep 10
    fi

    aws lambda create-function \
        --function-name "${FUNCTION_NAME}" \
        --runtime python3.11 \
        --role "${ROLE_ARN}" \
        --handler lambda_function.lambda_handler \
        --zip-file "fileb://${ZIP_PATH}" \
        --region "${REGION}" \
        --timeout 30 \
        --memory-size 128 >/dev/null
fi

wait_for_lambda_ready "${FUNCTION_NAME}"

# ── Step 6: Publish version ────────────────────────────────────────────────────
echo ""
echo "[DEPLOY] Step 6: Publishing version..."
VERSION_NUMBER=$(aws lambda publish-version \
    --function-name "${FUNCTION_NAME}" \
    --region "${REGION}" \
    --query 'Version' \
    --output text)
echo "Published Lambda version: ${VERSION_NUMBER}"

# ── Step 7: Smoke test ─────────────────────────────────────────────────────────
echo ""
echo "[TEST] Step 7: Smoke test..."
RESPONSE_FILE="${BUILD_DIR}/response.json"
aws lambda invoke \
    --function-name "${FUNCTION_NAME}:${VERSION_NUMBER}" \
    --region "${REGION}" \
    "${RESPONSE_FILE}" >/dev/null

python3 - <<'PY' "${RESPONSE_FILE}"
import json
import sys

response_path = sys.argv[1]
with open(response_path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)

body = payload.get('body')
if isinstance(body, str):
    body = json.loads(body)

message = body.get('message') if isinstance(body, dict) else None
if message != 'Success!':
    raise SystemExit(f"Smoke test failed: unexpected message {message!r}")
PY

echo "✓ Smoke test passed!"

echo ""
echo "=========================================="
echo "Pipeline Complete!"
echo "Deployed version : ${VERSION_NUMBER}"
echo "=========================================="
