#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup-terraform-backend.sh — Bootstrap Remote State Storage
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT THIS SCRIPT DOES:
# ─────────────────────────────────────────────────────────────────────────────
# Creates the S3 bucket and DynamoDB table needed for Terraform remote state.
# Run this ONCE before `terraform init` for the first time.
#
# WHY MANUAL BOOTSTRAP:
# These resources can't be managed by the same Terraform config that uses them.
# (If they were, Terraform would need state to create the state bucket — circular!)
# This is a one-time manual operation per AWS account.
#
# USAGE:
#   export AWS_REGION=us-east-1
#   export BUCKET_NAME=three-tier-eks-terraform-state  # Must be globally unique!
#   export DYNAMODB_TABLE=three-tier-eks-terraform-locks
#   chmod +x scripts/setup-terraform-backend.sh
#   ./scripts/setup-terraform-backend.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="${BUCKET_NAME:?ERROR: Set BUCKET_NAME env var (must be globally unique)}"
DYNAMODB_TABLE="${DYNAMODB_TABLE:-three-tier-eks-terraform-locks}"

# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────
command -v aws &>/dev/null || error "AWS CLI not found"
aws sts get-caller-identity &>/dev/null || error "AWS credentials not configured"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "AWS Account: ${ACCOUNT_ID}"
log "AWS Region: ${AWS_REGION}"
log "S3 Bucket: ${BUCKET_NAME}"
log "DynamoDB Table: ${DYNAMODB_TABLE}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: CREATE S3 BUCKET
# ─────────────────────────────────────────────────────────────────────────────
log "Creating S3 bucket for Terraform state..."

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    warn "Bucket ${BUCKET_NAME} already exists. Skipping creation."
else
    # us-east-1 does NOT use CreateBucketConfiguration (unique AWS quirk!)
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}"
    else
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}" \
            --create-bucket-configuration LocationConstraint="${AWS_REGION}"
    fi
    success "S3 bucket created: ${BUCKET_NAME}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: ENABLE VERSIONING
# ─────────────────────────────────────────────────────────────────────────────
# Versioning allows restoring a previous state if current state is corrupted.
log "Enabling S3 versioning..."
aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled
success "Versioning enabled on ${BUCKET_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: ENABLE SERVER-SIDE ENCRYPTION (KMS)
# ─────────────────────────────────────────────────────────────────────────────
# Terraform state may contain sensitive values. Encrypt at rest with KMS.
log "Enabling KMS encryption on S3 bucket..."
aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "aws:kms"
            },
            "BucketKeyEnabled": true
        }]
    }'
success "KMS encryption enabled"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: BLOCK PUBLIC ACCESS
# ─────────────────────────────────────────────────────────────────────────────
log "Blocking all public access to the state bucket..."
aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true
success "Public access blocked"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: CREATE DYNAMODB TABLE FOR LOCKING
# ─────────────────────────────────────────────────────────────────────────────
log "Creating DynamoDB table for state locking..."

if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" \
    --region "${AWS_REGION}" 2>/dev/null | grep -q ACTIVE; then
    warn "DynamoDB table ${DYNAMODB_TABLE} already exists. Skipping."
else
    aws dynamodb create-table \
        --table-name "${DYNAMODB_TABLE}" \
        --region "${AWS_REGION}" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --tags Key=Project,Value=three-tier-eks-portfolio \
               Key=ManagedBy,Value=terraform-bootstrap
    success "DynamoDB table created: ${DYNAMODB_TABLE}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  TERRAFORM BACKEND SETUP COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "State bucket: s3://${BUCKET_NAME}"
echo "  - Versioning: ENABLED"
echo "  - Encryption: KMS"
echo "  - Public access: BLOCKED"
echo ""
echo "Lock table: ${DYNAMODB_TABLE} (DynamoDB, PAY_PER_REQUEST)"
echo ""
echo "Next steps:"
echo "  1. Update terraform/main.tf backend block with your bucket name:"
echo "     bucket = \"${BUCKET_NAME}\""
echo "  2. Run: cd terraform && terraform init"
echo "  3. Run: terraform plan -var-file=terraform.tfvars"
echo "  4. Run: terraform apply -var-file=terraform.tfvars"
