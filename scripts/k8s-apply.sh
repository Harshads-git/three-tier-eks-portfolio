#!/bin/bash
# scripts/k8s-apply.sh
# ─────────────────────────────────────────────────────────────────────────────
# Apply ALL Kubernetes manifests in the correct dependency order.
# Referenced by: README.md Quick Start, Makefile k8s-apply target,
#                docs/disaster-recovery.md (cluster reconstruction)
#
# DEPENDENCY ORDER:
#   1. Namespace    — must exist before any namespaced resources
#   2. ResourceQuota + LimitRange — governance before workloads
#   3. NetworkPolicies — security before workloads (deny-all first)
#   4. Workloads (mongo → backend → frontend) — data tier before API before UI
#   5. Ingress — requires services to exist
#   6. PDB — requires deployments to exist (selector must match running pods)
#   7. Monitoring — optional, can be applied separately
#
# USAGE:
#   chmod +x scripts/k8s-apply.sh
#   ./scripts/k8s-apply.sh                    # Apply all (skip monitoring)
#   ./scripts/k8s-apply.sh --with-monitoring  # Include Prometheus/Grafana CRDs
#   ./scripts/k8s-apply.sh --dry-run          # Preview without applying
#
# EXPECTED COMPLETION TIME: ~3-5 minutes (ALB provisioning takes 2-3 min)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
WITH_MONITORING=false
DRY_RUN=false
KUBECTL_FLAGS=""

for arg in "$@"; do
  case $arg in
    --with-monitoring) WITH_MONITORING=true ;;
    --dry-run)         DRY_RUN=true; KUBECTL_FLAGS="--dry-run=client" ;;
    --help|-h)
      echo "Usage: $0 [--with-monitoring] [--dry-run]"
      echo "  --with-monitoring  Also apply ServiceMonitors and alert rules"
      echo "  --dry-run          Validate manifests without applying"
      exit 0
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}[$(date +%H:%M:%S)] Step $1: $2${NC}"; }
log_ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
log_warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
log_err()  { echo -e "${RED}  ✗ $1${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Three-Tier EKS — Kubernetes Apply Script        ${NC}"
echo -e "${BLUE}   Mode: $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'LIVE APPLY')${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

# Check kubectl is connected
if ! kubectl cluster-info &>/dev/null; then
  log_err "Cannot connect to Kubernetes cluster!"
  echo "  Run: aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1"
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
log_ok "Connected to: ${CURRENT_CONTEXT}"

if [ "$DRY_RUN" = false ]; then
  echo -e "\n${YELLOW}Applying to context: ${CURRENT_CONTEXT}${NC}"
  echo "Press Ctrl+C to cancel (5 seconds)..."
  sleep 5
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: NAMESPACE
# ─────────────────────────────────────────────────────────────────────────────
log_step "1/7" "Creating namespace"
kubectl apply $KUBECTL_FLAGS -f k8s/mongo/namespace.yaml
log_ok "Namespace: three-tier"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: RESOURCE GOVERNANCE
# ─────────────────────────────────────────────────────────────────────────────
log_step "2/7" "Applying resource governance (ResourceQuota + LimitRange)"
kubectl apply $KUBECTL_FLAGS -f k8s/resource-quota/quotas.yaml
log_ok "ResourceQuota: two CPU, 1Gi RAM, no LoadBalancer services"
log_ok "LimitRange: default requests/limits injected for containers without specs"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: NETWORK POLICIES
# ─────────────────────────────────────────────────────────────────────────────
log_step "3/7" "Applying NetworkPolicies (zero-trust)"
kubectl apply $KUBECTL_FLAGS -f k8s/network-policies/deny-all.yaml
log_ok "Default deny-all: ALL traffic blocked"
kubectl apply $KUBECTL_FLAGS -f k8s/network-policies/allow-ingress.yaml
log_ok "Allow rules: ALB→frontend, frontend→backend, backend→MongoDB, DNS"

if [ "$DRY_RUN" = false ]; then
  log_warn "NetworkPolicy enforcement requires VPC CNI NetworkPolicy agent."
  log_warn "Enable: aws eks update-addon vpc-cni --configuration-values '{\"enableNetworkPolicy\":\"true\"}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: WORKLOADS (data → api → presentation)
# ─────────────────────────────────────────────────────────────────────────────
log_step "4a/7" "Deploying MongoDB (data tier)"
kubectl apply $KUBECTL_FLAGS -f k8s/mongo/
log_ok "StatefulSet: mongo (1 replica, 5Gi EBS PVC)"
log_ok "Service: mongo-service (ClusterIP:27017)"
log_ok "Secret: mongo-secret (credentials)"

if [ "$DRY_RUN" = false ]; then
  echo "  Waiting for MongoDB to be Ready..."
  kubectl rollout status statefulset/mongo -n three-tier --timeout=120s
  log_ok "MongoDB is Ready"
fi

log_step "4b/7" "Deploying Backend (API tier)"
kubectl apply $KUBECTL_FLAGS -f k8s/backend/
log_ok "Deployment: backend (2 replicas, HPA 2-5)"
log_ok "Service: backend-service (NodePort:30050)"
log_ok "HPA: backend-hpa (CPU target: 70%)"
log_ok "ConfigMap: backend-config (MONGO_URI, NODE_ENV)"

if [ "$DRY_RUN" = false ]; then
  echo "  Waiting for backend to be Ready..."
  kubectl rollout status deployment/backend -n three-tier --timeout=120s
  log_ok "Backend is Ready"
fi

log_step "4c/7" "Deploying Frontend (presentation tier)"
kubectl apply $KUBECTL_FLAGS -f k8s/frontend/
log_ok "Deployment: frontend (2 replicas, HPA 2-5)"
log_ok "Service: frontend-service (NodePort:30080)"
log_ok "HPA: frontend-hpa (CPU target: 70%)"

if [ "$DRY_RUN" = false ]; then
  echo "  Waiting for frontend to be Ready..."
  kubectl rollout status deployment/frontend -n three-tier --timeout=120s
  log_ok "Frontend is Ready"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: INGRESS (ALB)
# ─────────────────────────────────────────────────────────────────────────────
log_step "5/7" "Creating Ingress (ALB provisioning)"
kubectl apply $KUBECTL_FLAGS -f k8s/ingress/
log_ok "Ingress: three-tier-ingress (ALB class)"
log_ok "Rules: /* → frontend-service, /api/* → backend-service"

if [ "$DRY_RUN" = false ]; then
  echo "  Waiting for ALB to be provisioned (this takes 2-3 minutes)..."
  for i in $(seq 1 18); do
    ALB_DNS=$(kubectl get ingress three-tier-ingress -n three-tier \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_DNS" ]; then
      log_ok "ALB provisioned: http://${ALB_DNS}"
      break
    fi
    echo -n "  ."
    sleep 10
  done
  if [ -z "$ALB_DNS" ]; then
    log_warn "ALB DNS not yet available. Check: kubectl get ingress -n three-tier -w"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: POD DISRUPTION BUDGETS
# ─────────────────────────────────────────────────────────────────────────────
log_step "6/7" "Applying PodDisruptionBudgets"
kubectl apply $KUBECTL_FLAGS -f k8s/pdb/poddisruptionbudgets.yaml
log_ok "PDB: frontend-pdb (minAvailable: 1)"
log_ok "PDB: backend-pdb (minAvailable: 1)"
log_ok "PDB: mongo-pdb (minAvailable: 1 — blocks all voluntary evictions)"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: MONITORING (optional)
# ─────────────────────────────────────────────────────────────────────────────
log_step "7/7" "Monitoring"
if [ "$WITH_MONITORING" = true ]; then
  kubectl apply $KUBECTL_FLAGS -f k8s/monitoring/servicemonitors.yaml
  kubectl apply $KUBECTL_FLAGS -f k8s/monitoring/alerting-rules.yaml
  log_ok "ServiceMonitors: backend, frontend, MongoDB"
  log_ok "PrometheusRule: 8 custom alert rules"
else
  log_warn "Skipped (run with --with-monitoring to include)"
  log_warn "Or: kubectl apply -f k8s/monitoring/"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FINAL STATUS
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
if [ "$DRY_RUN" = true ]; then
  echo -e "${GREEN}  ✓ Dry run complete — all manifests are valid!${NC}"
  echo -e "    Run without --dry-run to apply."
else
  echo -e "${GREEN}  ✓ All resources applied successfully!${NC}"
  echo ""
  echo "  Verify deployment:"
  echo "    kubectl get pods -n three-tier"
  echo "    kubectl get hpa,pdb -n three-tier"
  echo "    kubectl get ingress -n three-tier"
  echo ""
  if [ -n "${ALB_DNS:-}" ]; then
    echo -e "  ${GREEN}Application URL: http://${ALB_DNS}${NC}"
  fi
fi
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
