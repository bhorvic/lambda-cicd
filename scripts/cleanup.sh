#!/bin/bash
# scripts/cleanup.sh - Delete deployed Lambda functions and layers used for testing
#
# Usage:
#   ./scripts/cleanup.sh
#
# This script deletes the functions listed in FUNCTIONS and all versions
# of the Lambda layer named in LAYER_NAME. Edit both lists as needed.
#
# If deploy.sh auto-created an S3 bucket (i.e. BUCKET_NAME was not set in
# config/config.env), it will be emptied and deleted here too.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUTO_BUCKET_FILE="${REPO_ROOT}/.auto_created_bucket"

FUNCTIONS=(
    my-test-lambda
    my-experimental-lambda
    lambda-with-requests
    my-cicd-lambda
)

LAYER_NAME="requests-layer"

# ── Functions ──────────────────────────────────────────────────────────────────
echo "Cleaning up Lambda functions..."
for func in "${FUNCTIONS[@]}"; do
    if aws lambda get-function --function-name "${func}" 2>/dev/null; then
        echo "Deleting ${func}..."
        aws lambda delete-function --function-name "${func}"
    else
        echo "Skipping ${func} (not found)"
    fi
done

# ── Layers ─────────────────────────────────────────────────────────────────────
echo ""
echo "Cleaning up Lambda layer: ${LAYER_NAME}..."
LAYER_VERSIONS=$(aws lambda list-layer-versions \
    --layer-name "${LAYER_NAME}" \
    --query 'LayerVersions[*].Version' \
    --output text 2>/dev/null || echo "")

if [ -n "${LAYER_VERSIONS}" ]; then
    for version in ${LAYER_VERSIONS}; do
        echo "Deleting layer version ${version}..."
        aws lambda delete-layer-version \
            --layer-name "${LAYER_NAME}" \
            --version-number "${version}"
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
    aws s3 rm "s3://${AUTO_BUCKET}" --recursive

    aws s3api delete-bucket --bucket "${AUTO_BUCKET}"
    rm "${AUTO_BUCKET_FILE}"
    echo "✓ Bucket ${AUTO_BUCKET} deleted."
else
    echo "No auto-created bucket to clean up (BUCKET_NAME was user-managed)."
fi

echo ""
echo "Cleanup complete!"
