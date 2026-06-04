#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/apply-k8s-manifests.sh — Full K8s Manifest Apply Script
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT THIS SCRIPT DOES:
# ─────────────────────────────────────────────────────────────────────────────
# Applies ALL Kubernetes manifests in the correct order, with health checks
# between stages to ensure each tier is ready before the next is applied.
#
# ORDER MATTERS:
#   1. Namespace           (must exist before any namespaced resources)
#   2. Config & Secrets    (must exist before Deployments that reference them)
#   3. MongoDB tier        (must be healthy before backend starts)
#   4. Backend tier        (must be healthy before Ingress is useful)
#   5. Frontend tier
#   6. Ingress             (wire everything together with ALB routing)
#
# PREREQUISITES:
#   - kubectl configured: kubectl config current-context
#   - Pointing to the correct EKS cluster
#   - AWS LB Controller installed (via Helm in Day 13)
#   - ECR images pushed (via scripts/build-and-push.sh or CI/CD Day 24)
#
# USAGE:
#   chmod +x scripts/apply-k8s-manifests.sh
#   ./scripts/apply-k8s-manifests.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# COLOR OUTPUT
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
NAMESPACE="three-tier"
MANIFESTS_DIR="$(dirname "$0")/../k8s"
KUBECTL_TIMEOUT="300s"   # 5 minutes wait for rollout

# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────
step "PREFLIGHT CHECKS"

command -v kubectl &>/dev/null || error "kubectl not found in PATH"

CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
log "kubectl context: ${CURRENT_CONTEXT}"
log "cluster: ${CURRENT_CLUSTER}"

read -r -p "Apply manifests to this cluster? [y/N] " confirm
[[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "Aborted."; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: NAMESPACE
# ─────────────────────────────────────────────────────────────────────────────
step "STEP 1/6: Namespace"

log "Applying namespace..."
kubectl apply -f "${MANIFESTS_DIR}/mongo/namespace.yaml"
success "Namespace 'three-tier' ready"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: CONFIG & SECRETS
# ─────────────────────────────────────────────────────────────────────────────
step "STEP 2/6: Configuration and Secrets"

log "Applying MongoDB Secret..."
kubectl apply -f "${MANIFESTS_DIR}/mongo/secret.yaml"
warn "REMINDER: secret.yaml has placeholder base64 values!"
warn "In production, inject real secrets from GitHub Secrets or AWS Secrets Manager."

log "Applying backend ConfigMap..."
kubectl apply -f "${MANIFESTS_DIR}/backend/configmap.yaml"

success "Config and Secrets applied"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: MONGODB (Tier 3 — Database)
# ─────────────────────────────────────────────────────────────────────────────
step "STEP 3/6: MongoDB (Tier 3)"

log "Applying MongoDB Services..."
kubectl apply -f "${MANIFESTS_DIR}/mongo/service.yaml"

log "Applying MongoDB StatefulSet..."
kubectl apply -f "${MANIFESTS_DIR}/mongo/statefulset.yaml"

log "Waiting for MongoDB StatefulSet to be ready (timeout: ${KUBECTL_TIMEOUT})..."
kubectl rollout status statefulset/mongo \
    -n "${NAMESPACE}" \
    --timeout="${KUBECTL_TIMEOUT}"

success "MongoDB is ready!"

# Verify MongoDB is accepting connections
log "Verifying MongoDB connection..."
kubectl exec -it mongo-0 -n "${NAMESPACE}" -- \
    mongosh --eval "db.adminCommand('ping')" --quiet \
    2>/dev/null | grep -q '"ok"' && \
    success "MongoDB ping: OK" || \
    warn "MongoDB ping check failed — check pod logs: kubectl logs mongo-0 -n ${NAMESPACE}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: BACKEND (Tier 2 — Logic)
# ─────────────────────────────────────────────────────────────────────────────
step "STEP 4/6: Backend (Tier 2)"

log "Applying backend Service..."
kubectl apply -f "${MANIFESTS_DIR}/backend/service.yaml"

log "Applying backend Deployment..."
kubectl apply -f "${MANIFESTS_DIR}/backend/deployment.yaml"

log "Applying backend HPA..."
kubectl apply -f "${MANIFESTS_DIR}/backend/hpa.yaml"

log "Waiting for backend Deployment to roll out..."
kubectl rollout status deployment/backend \
    -n "${NAMESPACE}" \
    --timeout="${KUBECTL_TIMEOUT}"

success "Backend is ready!"

# Quick API health check
log "Checking backend API health..."
BACKEND_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=backend \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "${BACKEND_POD}" ]]; then
    HEALTH=$(kubectl exec "${BACKEND_POD}" -n "${NAMESPACE}" -- \
        wget --quiet --output-document=- http://localhost:5000/health 2>/dev/null || echo "")
    if echo "${HEALTH}" | grep -q '"status":"ok"'; then
        success "Backend /health: OK (MongoDB connected)"
    else
        warn "Backend /health returned unexpected response. Check logs:"
        warn "kubectl logs ${BACKEND_POD} -n ${NAMESPACE}"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: FRONTEND (Tier 1 — Presentation)
# ─────────────────────────────────────────────────────────────────────────────
step "STEP 5/6: Frontend (Tier 1)"

log "Applying frontend Service..."
kubectl apply -f "${MANIFESTS_DIR}/frontend/service.yaml"

log "Applying frontend Deployment..."
kubectl apply -f "${MANIFESTS_DIR}/frontend/deployment.yaml"

log "Applying frontend HPA..."
kubectl apply -f "${MANIFESTS_DIR}/frontend/hpa.yaml"

log "Waiting for frontend Deployment to roll out..."
kubectl rollout status deployment/frontend \
    -n "${NAMESPACE}" \
    --timeout="${KUBECTL_TIMEOUT}"

success "Frontend is ready!"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: INGRESS (ALB)
# ─────────────────────────────────────────────────────────────────────────────
step "STEP 6/6: Ingress (ALB)"

log "Applying Ingress (this triggers ALB provisioning)..."
kubectl apply -f "${MANIFESTS_DIR}/ingress.yaml"

log "Waiting for ALB to be provisioned (up to 3 minutes)..."
# The AWS LB Controller takes ~2 minutes to provision the ALB
for i in {1..18}; do
    ALB_DNS=$(kubectl get ingress three-tier-ingress -n "${NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "${ALB_DNS}" ]]; then
        success "ALB provisioned: ${ALB_DNS}"
        break
    fi
    log "Waiting for ALB... attempt ${i}/18 (${i}0s elapsed)"
    sleep 10
done

if [[ -z "${ALB_DNS:-}" ]]; then
    warn "ALB not yet provisioned. Check AWS LB Controller logs:"
    warn "kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo "Cluster resources:"
kubectl get all -n "${NAMESPACE}" 2>/dev/null
echo ""
echo "HPA status:"
kubectl get hpa -n "${NAMESPACE}" 2>/dev/null
echo ""
if [[ -n "${ALB_DNS:-}" ]]; then
    echo -e "${GREEN}Application URLs:${NC}"
    echo "  HTTP (redirects to HTTPS): http://${ALB_DNS}"
    echo "  HTTPS:                     https://${ALB_DNS}"
    echo "  API test:                  curl https://${ALB_DNS}/api/tasks"
    echo "  Health check:              curl https://${ALB_DNS}/api/tasks (expect [])"
fi
echo ""
warn "DNS propagation may take 2-5 minutes after ALB is provisioned."
warn "If using a custom domain (Day 15), update Route 53 with: CNAME ${ALB_DNS}"
