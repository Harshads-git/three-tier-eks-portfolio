#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/build-and-push.sh — Docker Build & ECR Push Script
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT THIS SCRIPT DOES:
# ─────────────────────────────────────────────────────────────────────────────
# Builds Docker images for both the backend and frontend and pushes them
# to Amazon ECR (Elastic Container Registry).
#
# Used for:
#   1. Manual image pushes during development (before CI/CD is set up Day 24)
#   2. Reference for what the GitHub Actions workflow (Day 24) does automatically
#
# PREREQUISITES:
# ─────────────────────────────────────────────────────────────────────────────
# 1. AWS CLI installed: aws --version
# 2. Docker installed and running: docker --version
# 3. AWS credentials configured: aws configure (or IAM role on EC2/Cloud9)
# 4. ECR repositories created via Terraform (Day 11+)
# 5. Required environment variables set (see CONFIGURATION section below)
#
# USAGE:
# ─────────────────────────────────────────────────────────────────────────────
#   # Set required variables first:
#   export AWS_ACCOUNT_ID=123456789012
#   export AWS_REGION=us-east-1
#   export IMAGE_TAG=v1.0.0     # or use: git rev-parse --short HEAD
#   export REACT_APP_BACKEND_URL=http://<ALB-DNS>/api/tasks
#
#   # Run the script:
#   chmod +x scripts/build-and-push.sh
#   ./scripts/build-and-push.sh
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
# set -e: Exit immediately on any error (don't continue if a command fails)
# set -u: Treat unset variables as errors (catches typos in variable names)
# set -o pipefail: A pipe fails if ANY command in it fails (not just the last)

# ─────────────────────────────────────────────────────────────────────────────
# COLOR OUTPUT
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log()     { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Set via environment variables before running
# ─────────────────────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?ERROR: AWS_ACCOUNT_ID must be set}"
AWS_REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')}"

# ECR Repository names (must match terraform/ecr.tf)
BACKEND_REPO="three-tier-backend"
FRONTEND_REPO="three-tier-frontend"

# ECR Registry URL
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# React backend URL — baked into the frontend image at build time
REACT_APP_BACKEND_URL="${REACT_APP_BACKEND_URL:?ERROR: REACT_APP_BACKEND_URL must be set}"

# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
log "Running preflight checks..."

command -v docker &>/dev/null || error "Docker is not installed or not in PATH"
command -v aws    &>/dev/null || error "AWS CLI is not installed or not in PATH"

# Verify AWS credentials are configured
aws sts get-caller-identity &>/dev/null || error "AWS credentials not configured. Run: aws configure"

success "All preflight checks passed"
log "AWS Account: ${AWS_ACCOUNT_ID}"
log "AWS Region:  ${AWS_REGION}"
log "Image Tag:   ${IMAGE_TAG}"
log "ECR Registry: ${ECR_REGISTRY}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: ECR AUTHENTICATION
# ─────────────────────────────────────────────────────────────────────────────
# ECR requires re-authentication every 12 hours.
# This command gets a temporary password and pipes it to docker login.
#
# In production (GitHub Actions), use OIDC instead of access keys:
#   - Configure GitHub OIDC provider in AWS IAM
#   - GitHub Actions assumes an IAM role automatically (no keys needed)
#   - This is covered in Day 24 (CI/CD pipeline)
log "Authenticating with ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"
success "ECR authentication successful"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: BUILD & PUSH BACKEND IMAGE
# ─────────────────────────────────────────────────────────────────────────────
BACKEND_IMAGE="${ECR_REGISTRY}/${BACKEND_REPO}:${IMAGE_TAG}"
BACKEND_IMAGE_LATEST="${ECR_REGISTRY}/${BACKEND_REPO}:latest"

log "Building backend image: ${BACKEND_IMAGE}"
docker build \
    --platform linux/amd64 \
    # --platform linux/amd64: Build for x86_64 (EKS EC2 nodes are x86_64 by default)
    # On Apple M1/M2 Macs, Docker defaults to ARM64. This flag ensures the correct arch.
    # Without this, your ARM64 image will fail to run on x86_64 EKS nodes.
    --tag "${BACKEND_IMAGE}" \
    --tag "${BACKEND_IMAGE_LATEST}" \
    --file app/backend/Dockerfile \
    app/backend/

success "Backend image built: ${BACKEND_IMAGE}"

log "Pushing backend image to ECR..."
docker push "${BACKEND_IMAGE}"
docker push "${BACKEND_IMAGE_LATEST}"
success "Backend image pushed: ${BACKEND_IMAGE}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: BUILD & PUSH FRONTEND IMAGE
# ─────────────────────────────────────────────────────────────────────────────
FRONTEND_IMAGE="${ECR_REGISTRY}/${FRONTEND_REPO}:${IMAGE_TAG}"
FRONTEND_IMAGE_LATEST="${ECR_REGISTRY}/${FRONTEND_REPO}:latest"

log "Building frontend image: ${FRONTEND_IMAGE}"
log "Using REACT_APP_BACKEND_URL: ${REACT_APP_BACKEND_URL}"

docker build \
    --platform linux/amd64 \
    --build-arg "REACT_APP_BACKEND_URL=${REACT_APP_BACKEND_URL}" \
    # --build-arg passes the backend URL into the Dockerfile ARG instruction.
    # This is baked into the React bundle during `npm run build` inside the Dockerfile.
    --tag "${FRONTEND_IMAGE}" \
    --tag "${FRONTEND_IMAGE_LATEST}" \
    --file app/frontend/Dockerfile \
    app/frontend/

success "Frontend image built: ${FRONTEND_IMAGE}"

log "Pushing frontend image to ECR..."
docker push "${FRONTEND_IMAGE}"
docker push "${FRONTEND_IMAGE_LATEST}"
success "Frontend image pushed: ${FRONTEND_IMAGE}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  BUILD AND PUSH COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo "Backend image:"
echo "  ${BACKEND_IMAGE}"
echo "  ${BACKEND_IMAGE_LATEST}"
echo ""
echo "Frontend image:"
echo "  ${FRONTEND_IMAGE}"
echo "  ${FRONTEND_IMAGE_LATEST}"
echo ""
echo "Next steps:"
echo "  1. Update k8s/backend/deployment.yaml image: ${BACKEND_IMAGE}"
echo "  2. Update k8s/frontend/deployment.yaml image: ${FRONTEND_IMAGE}"
echo "  3. kubectl apply -f k8s/ -n three-tier"
echo ""
warn "In CI/CD (Day 24), this script is replaced by GitHub Actions."
warn "The GitHub Actions workflow uses OIDC (no long-term AWS keys)."
