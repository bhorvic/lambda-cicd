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

set -e

# ── Config ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: config/config.env not found."
    echo "Copy config/config.env.example to config/config.env and fill in your values."
    exit 1
fi

source "${CONFIG_FILE}"

: "${REGION:?config.env must define REGION}"
: "${FUNCTION_NAME:?config.env must define FUNCTION_NAME}"
: "${ROLE_NAME:=lambda-basic-execution-role}"

# BUCKET_NAME is optional — if not set, auto-generate one from the account ID
BUCKET_OWNER_MANAGED=false
if [ -z "${BUCKET_NAME}" ]; then
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
(cd "${SRC_DIR}" && zip "${ZIP_PATH}" lambda_function.py)
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
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${REGION}" 2>/dev/null; then
    echo "Function exists — updating code..."
    aws lambda update-function-code \
        --function-name "${FUNCTION_NAME}" \
        --s3-bucket "${BUCKET_NAME}" \
        --s3-key "lambda-builds/${ZIP_NAME}" \
        --region "${REGION}"
else
    echo "Function not found — creating it..."

    if aws iam get-role --role-name "${ROLE_NAME}" 2>/dev/null; then
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
        --memory-size 128
fi

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
    "${RESPONSE_FILE}"

STATUS_CODE=$(python3 -c "import json; d=json.load(open('${RESPONSE_FILE}')); print(d.get('statusCode', 0))" 2>/dev/null || echo 0)
if [ "${STATUS_CODE}" = "200" ]; then
    echo "✓ Smoke test passed! (statusCode: ${STATUS_CODE})"
else
    echo "✗ Smoke test failed! (statusCode: ${STATUS_CODE})"
    echo "Response:"
    cat "${RESPONSE_FILE}"
    exit 1
fi

# ── Step 8: Cleanup ────────────────────────────────────────────────────────────
echo ""
echo "[CLEANUP] Step 8: Cleaning up build artifacts..."
rm -rf "${BUILD_DIR}"

echo ""
echo "=========================================="
echo "Pipeline Complete!"
echo "Deployed version : ${VERSION_NUMBER}"
echo "=========================================="
