#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/generate-sbom.sh — Local Software Bill of Materials (SBOM) Generator
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE:
#   Generates an industry-standard CycloneDX and SPDX Software Bill of Materials
#   for the Three-Tier container images using Anchore Syft.
#
# USAGE:
#   chmod +x scripts/generate-sbom.sh
#   ./scripts/generate-sbom.sh [IMAGE_NAME] [OUTPUT_DIR]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TARGET_IMAGE="${1:-three-tier-backend:latest}"
OUTPUT_DIR="${2:-./sbom-reports}"
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "${OUTPUT_DIR}"

echo -e "${BLUE}Generating Software Bill of Materials for: ${TARGET_IMAGE}...${NC}"

# Check if Syft is installed
if ! command -v syft &>/dev/null; then
  echo -e "${RED}Error: 'syft' CLI is not installed.${NC}"
  echo "Install via: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin"
  exit 1
fi

SANITIZED_NAME=$(echo "${TARGET_IMAGE}" | tr '/:' '_')

# 1. CycloneDX JSON format (OWASP standard)
echo "Generating CycloneDX JSON SBOM..."
syft "${TARGET_IMAGE}" -o cyclonedx-json > "${OUTPUT_DIR}/${SANITIZED_NAME}-cyclonedx.json"
echo -e "${GREEN}✓ Created: ${OUTPUT_DIR}/${SANITIZED_NAME}-cyclonedx.json${NC}"

# 2. SPDX JSON format (Linux Foundation / ISO standard)
echo "Generating SPDX JSON SBOM..."
syft "${TARGET_IMAGE}" -o spdx-json > "${OUTPUT_DIR}/${SANITIZED_NAME}-spdx.json"
echo -e "${GREEN}✓ Created: ${OUTPUT_DIR}/${SANITIZED_NAME}-spdx.json${NC}"

# 3. Human-readable package inventory table
echo "Generating package inventory table..."
syft "${TARGET_IMAGE}" -o table > "${OUTPUT_DIR}/${SANITIZED_NAME}-inventory.txt"
echo -e "${GREEN}✓ Created: ${OUTPUT_DIR}/${SANITIZED_NAME}-inventory.txt${NC}"

echo -e "${BLUE}SBOM generation complete! Files saved to: ${OUTPUT_DIR}${NC}"
