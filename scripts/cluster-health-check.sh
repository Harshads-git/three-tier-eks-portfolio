#!/bin/bash
# scripts/cluster-health-check.sh
# ─────────────────────────────────────────────────────────────────────────────
# Comprehensive cluster health check script.
# Run daily or before/after any cluster operation.
#
# USAGE:
#   chmod +x scripts/cluster-health-check.sh
#   ./scripts/cluster-health-check.sh
#   ./scripts/cluster-health-check.sh --namespace three-tier
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE=${1:-three-tier}
ISSUES=0

log_ok()   { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; ISSUES=$((ISSUES+1)); }
log_err()  { echo -e "${RED}✗${NC} $1"; ISSUES=$((ISSUES+1)); }
log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
section()  { echo -e "\n${BLUE}═══ $1 ═══${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
section "CLUSTER CONNECTIVITY"
# ─────────────────────────────────────────────────────────────────────────────
if kubectl cluster-info &>/dev/null; then
  log_ok "Cluster reachable: $(kubectl config current-context)"
else
  log_err "Cannot connect to cluster! Check: aws eks update-kubeconfig --name three-tier-eks-cluster --region us-east-1"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
section "NODE STATUS"
# ─────────────────────────────────────────────────────────────────────────────
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready " || true)
NOT_READY=$(kubectl get nodes --no-headers | grep -c "NotReady" || true)

if [ "$NOT_READY" -gt 0 ]; then
  log_err "$NOT_READY/$TOTAL_NODES nodes are NotReady"
  kubectl get nodes | grep NotReady
else
  log_ok "$READY_NODES/$TOTAL_NODES nodes are Ready"
fi
kubectl get nodes -o wide --no-headers | awk '{print "  " $1 " | " $2 " | " $5 " | " $6}'

# ─────────────────────────────────────────────────────────────────────────────
section "POD STATUS ($NAMESPACE)"
# ─────────────────────────────────────────────────────────────────────────────
CRASH_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -E "CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff" | wc -l || true)
PENDING_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -c "Pending" || true)

if [ "$CRASH_PODS" -gt 0 ]; then
  log_err "$CRASH_PODS pod(s) in error state:"
  kubectl get pods -n "$NAMESPACE" | grep -E "CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff"
else
  log_ok "No pods in error state"
fi

if [ "$PENDING_PODS" -gt 0 ]; then
  log_warn "$PENDING_PODS pod(s) in Pending state (may be scheduling)"
  kubectl get pods -n "$NAMESPACE" | grep "Pending"
else
  log_ok "No pods in Pending state"
fi

# Check restart counts
HIGH_RESTARTS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | awk '{if($4 > 5) print $0}' || true)
if [ -n "$HIGH_RESTARTS" ]; then
  log_warn "Pods with high restart counts:"
  echo "$HIGH_RESTARTS"
else
  log_ok "No pods with excessive restarts"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "HPA STATUS"
# ─────────────────────────────────────────────────────────────────────────────
while IFS= read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  CURRENT=$(echo "$line" | awk '{print $6}')
  MAX=$(echo "$line" | awk '{print $5}')
  if [ "$CURRENT" = "$MAX" ]; then
    log_warn "HPA $NAME is at max replicas ($CURRENT/$MAX) — capacity may be insufficient"
  else
    log_ok "HPA $NAME: $CURRENT/$MAX replicas"
  fi
done < <(kubectl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null || true)

# ─────────────────────────────────────────────────────────────────────────────
section "PDB STATUS"
# ─────────────────────────────────────────────────────────────────────────────
kubectl get pdb -n "$NAMESPACE" --no-headers 2>/dev/null | while IFS= read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  ALLOWED=$(echo "$line" | awk '{print $4}')
  log_info "PDB $NAME: $ALLOWED disruption(s) allowed"
done

# ─────────────────────────────────────────────────────────────────────────────
section "RESOURCE USAGE"
# ─────────────────────────────────────────────────────────────────────────────
if kubectl top pods -n "$NAMESPACE" &>/dev/null; then
  log_info "Pod resource usage:"
  kubectl top pods -n "$NAMESPACE" | awk 'NR==1{print "  "$0} NR>1{print "  "$0}'
else
  log_warn "Metrics Server not available (kubectl top not working)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "PERSISTENT VOLUME CLAIMS"
# ─────────────────────────────────────────────────────────────────────────────
UNBOUND=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -cv "Bound" || true)
if [ "$UNBOUND" -gt 0 ]; then
  log_err "$UNBOUND PVC(s) are not Bound:"
  kubectl get pvc -n "$NAMESPACE" | grep -v "Bound"
else
  log_ok "All PVCs are Bound"
  kubectl get pvc -n "$NAMESPACE" --no-headers | awk '{print "  " $1 ": " $2 " (" $4 ")"}'
fi

# ─────────────────────────────────────────────────────────────────────────────
section "RECENT EVENTS (last 30 min)"
# ─────────────────────────────────────────────────────────────────────────────
WARNINGS=$(kubectl get events -n "$NAMESPACE" \
  --field-selector type=Warning \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10)
if [ -n "$WARNINGS" ]; then
  log_warn "Recent warning events:"
  echo "$WARNINGS"
else
  log_ok "No recent warning events"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────
if [ "$ISSUES" -eq 0 ]; then
  echo -e "\n${GREEN}✓ All checks passed! Cluster is healthy.${NC}\n"
else
  echo -e "\n${RED}✗ $ISSUES issue(s) found. Review the warnings above.${NC}\n"
  exit 1
fi
