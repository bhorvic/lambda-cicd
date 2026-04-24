#!/bin/bash
# scripts/cleanup.sh - Delete deployed Lambda resources created for this repo
#
# Usage:
#   ./scripts/cleanup.sh
#
# This script deletes the configured Lambda function from config/config.env,
# any extra functions listed in EXTRA_FUNCTIONS, all versions of the Lambda
# layer named in LAYER_NAME, and an auto-created S3 bucket if deploy.sh made one.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/config.env"
AUTO_BUCKET_FILE="${REPO_ROOT}/.auto_created_bucket"

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: config/config.env not found."
    echo "Copy config/config.env.example to config/config.env and fill in your values."
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${REGION:?config.env must define REGION}"
: "${FUNCTION_NAME:?config.env must define FUNCTION_NAME}"

LAYER_NAME="${LAYER_NAME:-requests-layer}"
EXTRA_FUNCTIONS_RAW="${EXTRA_FUNCTIONS:-}"

FUNCTIONS=("${FUNCTION_NAME}")
if [ -n "${EXTRA_FUNCTIONS_RAW}" ]; then
    IFS=',' read -r -a EXTRA_FUNCTIONS_ARRAY <<< "${EXTRA_FUNCTIONS_RAW}"
    for func in "${EXTRA_FUNCTIONS_ARRAY[@]}"; do
        func="$(echo "${func}" | xargs)"
        if [ -n "${func}" ]; then
            FUNCTIONS+=("${func}")
        fi
    done
fi

# ── Functions ──────────────────────────────────────────────────────────────────
echo "Cleaning up Lambda functions in ${REGION}..."
for func in "${FUNCTIONS[@]}"; do
    if aws lambda get-function --function-name "${func}" --region "${REGION}" >/dev/null 2>&1; then
        echo "Deleting ${func}..."
        aws lambda delete-function --function-name "${func}" --region "${REGION}"
    else
        echo "Skipping ${func} (not found)"
    fi
done

# ── Layers ─────────────────────────────────────────────────────────────────────
echo ""
echo "Cleaning up Lambda layer: ${LAYER_NAME}..."
LAYER_VERSIONS=$(aws lambda list-layer-versions \
    --layer-name "${LAYER_NAME}" \
    --region "${REGION}" \
    --query 'LayerVersions[*].Version' \
    --output text 2>/dev/null || echo "")

if [ -n "${LAYER_VERSIONS}" ]; then
    for version in ${LAYER_VERSIONS}; do
        echo "Deleting layer version ${version}..."
        aws lambda delete-layer-version \
            --layer-name "${LAYER_NAME}" \
            --version-number "${version}" \
            --region "${REGION}"
    done
else
    echo "No versions found for layer ${LAYER_NAME}"
fi

# ── Auto-created S3 bucket ────────────────────────────────────────────────────
echo ""
if [ -f "${AUTO_BUCKET_FILE}" ]; then
    AUTO_BUCKET=$(cat "${AUTO_BUCKET_FILE}")
    echo "Cleaning up auto-created S3 bucket: ${AUTO_BUCKET}..."

    # Empty the bucket first (delete-bucket fails if not empty)
    aws s3 rm "s3://${AUTO_BUCKET}" --recursive --region "${REGION}"
    aws s3api delete-bucket --bucket "${AUTO_BUCKET}" --region "${REGION}"

    rm "${AUTO_BUCKET_FILE}"
    echo "✓ Bucket ${AUTO_BUCKET} deleted."
else
    echo "No auto-created bucket to clean up (BUCKET_NAME was user-managed)."
fi

echo ""
echo "Cleanup complete!"
