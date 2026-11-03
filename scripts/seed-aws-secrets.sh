#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/seed-aws-secrets.sh — Populate AWS Secrets Manager for Three-Tier App
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE:
#   Creates the upstream secrets in AWS Secrets Manager that are automatically
#   synchronized into Kubernetes by the External Secrets Operator.
#
# USAGE:
#   chmod +x scripts/seed-aws-secrets.sh
#   ./scripts/seed-aws-secrets.sh [AWS_REGION]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

AWS_REGION="${1:-us-east-1}"
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${BLUE}Seeding AWS Secrets Manager in region: ${AWS_REGION}...${NC}"

# 1. MongoDB Credentials
echo "Creating/Updating secret: three-tier/production/mongodb..."
aws secretsmanager create-secret \
  --name "three-tier/production/mongodb" \
  --description "MongoDB root credentials and connection URI for Three-Tier EKS" \
  --region "${AWS_REGION}" \
  --secret-string '{
    "username": "admin",
    "password": "ProductionSuperSecurePassword2026!",
    "database": "tasksdb",
    "uri": "mongodb://admin:ProductionSuperSecurePassword2026!@mongo-service.three-tier.svc.cluster.local:27017/tasksdb?authSource=admin"
  }' 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id "three-tier/production/mongodb" \
  --region "${AWS_REGION}" \
  --secret-string '{
    "username": "admin",
    "password": "ProductionSuperSecurePassword2026!",
    "database": "tasksdb",
    "uri": "mongodb://admin:ProductionSuperSecurePassword2026!@mongo-service.three-tier.svc.cluster.local:27017/tasksdb?authSource=admin"
  }'

echo -e "${GREEN}✓ MongoDB secret seeded.${NC}"

# 2. Backend API Credentials
echo "Creating/Updating secret: three-tier/production/backend..."
aws secretsmanager create-secret \
  --name "three-tier/production/backend" \
  --description "JWT and API secrets for Backend API" \
  --region "${AWS_REGION}" \
  --secret-string '{
    "jwt_secret": "e9b7a42f61c30d8a5e4b7c1f8a9e2d3c4b5a6f7e8d9c0b1a2f3e4d5c6b7a8f9",
    "encryption_key": "k8s-three-tier-production-symmetric-key-256"
  }' 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id "three-tier/production/backend" \
  --region "${AWS_REGION}" \
  --secret-string '{
    "jwt_secret": "e9b7a42f61c30d8a5e4b7c1f8a9e2d3c4b5a6f7e8d9c0b1a2f3e4d5c6b7a8f9",
    "encryption_key": "k8s-three-tier-production-symmetric-key-256"
  }'

echo -e "${GREEN}✓ Backend API secrets seeded.${NC}"
echo -e "${BLUE}External Secrets Operator will automatically synchronize these into namespace 'three-tier'.${NC}"
