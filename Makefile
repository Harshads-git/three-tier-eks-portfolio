# ─────────────────────────────────────────────────────────────────────────────
# Makefile — Developer Experience Shortcuts
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE: Single entry point for all common operations.
# Reduces: "what was that kubectl command again?" friction.
#
# USAGE:
#   make help          # List all available targets
#   make local-up      # Start local development environment
#   make deploy        # Deploy to EKS
#   make health        # Run cluster health check
#   make smoke         # Run smoke test against cluster
#
# REQUIRES: docker, kubectl, terraform, k6, aws CLI
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: help local-up local-down local-logs local-clean \
        tf-init tf-plan tf-apply tf-destroy \
        k8s-apply k8s-delete k8s-status \
        health smoke load-test hpa-test \
        grafana prometheus port-forward-all \
        build-backend build-frontend \
        clean

# Default target: show help
.DEFAULT_GOAL := help

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES — Override at command line: make smoke BASE_URL=http://myalb.com
# ─────────────────────────────────────────────────────────────────────────────
NAMESPACE     ?= three-tier
CLUSTER_NAME  ?= three-tier-eks-cluster
AWS_REGION    ?= us-east-1
BASE_URL      ?= http://localhost:3000
MONITORING_NS ?= monitoring

# Colors
BLUE  := \033[34m
GREEN := \033[32m
RESET := \033[0m

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────
help: ## Show this help message
	@echo ""
	@echo "$(BLUE)Three-Tier EKS Portfolio — Make Targets$(RESET)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# LOCAL DEVELOPMENT (Docker Compose)
# ─────────────────────────────────────────────────────────────────────────────
local-up: ## Start local development environment (MongoDB + Backend + Frontend)
	@echo "$(BLUE)Starting local development environment...$(RESET)"
	docker compose up -d --build
	@echo "$(GREEN)✓ Services started:$(RESET)"
	@echo "  Frontend: http://localhost:3000"
	@echo "  Backend:  http://localhost:5000/api/health"
	@echo "  MongoDB:  mongodb://admin:devpassword@localhost:27017"

local-up-debug: ## Start with Mongo Express admin UI (port 8081)
	docker compose --profile debug up -d --build
	@echo "$(GREEN)✓ Mongo Express: http://localhost:8081$(RESET)"

local-down: ## Stop local development environment
	docker compose down
	@echo "$(GREEN)✓ Services stopped$(RESET)"

local-clean: ## Stop and DELETE all local data (MongoDB volume)
	docker compose down -v
	@echo "$(GREEN)✓ Services stopped and volumes deleted$(RESET)"

local-logs: ## Follow all local service logs
	docker compose logs -f

local-logs-backend: ## Follow backend logs only
	docker compose logs -f backend

local-status: ## Show status of local services
	docker compose ps

# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM — Infrastructure as Code
# ─────────────────────────────────────────────────────────────────────────────
tf-init: ## Initialize Terraform (download providers, configure backend)
	cd terraform && terraform init

tf-plan: ## Preview infrastructure changes
	cd terraform && terraform plan

tf-apply: ## Apply infrastructure changes (requires manual approval)
	cd terraform && terraform apply

tf-apply-auto: ## Apply without confirmation (use with caution!)
	cd terraform && terraform apply -auto-approve

tf-destroy: ## DESTROY all infrastructure (saves ~$163/month)
	@echo "$(BLUE)This will destroy ALL AWS infrastructure. Press Ctrl+C to cancel.$(RESET)"
	@sleep 3
	cd terraform && terraform destroy

tf-output: ## Show Terraform outputs (ECR URLs, cluster name, etc.)
	cd terraform && terraform output

tf-fmt: ## Format all Terraform files
	cd terraform && terraform fmt -recursive

# ─────────────────────────────────────────────────────────────────────────────
# KUBECTL — Cluster Connection
# ─────────────────────────────────────────────────────────────────────────────
kubeconfig: ## Configure kubectl for EKS cluster
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)
	@echo "$(GREEN)✓ kubectl configured for $(CLUSTER_NAME)$(RESET)"

# ─────────────────────────────────────────────────────────────────────────────
# KUBERNETES — Apply/Delete Manifests
# ─────────────────────────────────────────────────────────────────────────────
k8s-apply: ## Apply ALL Kubernetes manifests in correct order
	@echo "$(BLUE)Applying Kubernetes manifests...$(RESET)"
	kubectl apply -f k8s/mongo/namespace.yaml
	kubectl apply -f k8s/resource-quota/
	kubectl apply -f k8s/network-policies/
	kubectl apply -f k8s/mongo/
	kubectl apply -f k8s/backend/
	kubectl apply -f k8s/frontend/
	kubectl apply -f k8s/ingress/
	kubectl apply -f k8s/pdb/
	@echo "$(GREEN)✓ All manifests applied$(RESET)"

k8s-delete: ## Delete all application resources (keeps namespace)
	kubectl delete -f k8s/pdb/ --ignore-not-found
	kubectl delete -f k8s/ingress/ --ignore-not-found
	kubectl delete -f k8s/frontend/ --ignore-not-found
	kubectl delete -f k8s/backend/ --ignore-not-found
	kubectl delete -f k8s/mongo/ --ignore-not-found
	kubectl delete -f k8s/network-policies/ --ignore-not-found
	kubectl delete -f k8s/resource-quota/ --ignore-not-found

k8s-status: ## Show status of all resources in the namespace
	@echo "$(BLUE)=== PODS ===$(RESET)"
	kubectl get pods -n $(NAMESPACE) -o wide
	@echo ""
	@echo "$(BLUE)=== SERVICES ===$(RESET)"
	kubectl get svc -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)=== HPA ===$(RESET)"
	kubectl get hpa -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)=== INGRESS ===$(RESET)"
	kubectl get ingress -n $(NAMESPACE)
	@echo ""
	@echo "$(BLUE)=== PDB ===$(RESET)"
	kubectl get pdb -n $(NAMESPACE)

k8s-top: ## Show CPU/memory usage of pods
	kubectl top pods -n $(NAMESPACE) --containers

k8s-events: ## Show recent events (warnings first)
	kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' | tail -30

# ─────────────────────────────────────────────────────────────────────────────
# HEALTH & DIAGNOSTICS
# ─────────────────────────────────────────────────────────────────────────────
health: ## Run full cluster health check
	chmod +x scripts/cluster-health-check.sh
	./scripts/cluster-health-check.sh $(NAMESPACE)

alb-url: ## Get the ALB DNS name (application URL)
	@kubectl get ingress three-tier-ingress -n $(NAMESPACE) \
		-o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null \
		|| echo "Ingress not found or ALB not yet provisioned"

rollout-status: ## Check rollout status of all deployments
	kubectl rollout status deployment/backend -n $(NAMESPACE)
	kubectl rollout status deployment/frontend -n $(NAMESPACE)

rollback-backend: ## Emergency rollback: backend to previous version
	kubectl rollout undo deployment/backend -n $(NAMESPACE)
	kubectl rollout status deployment/backend -n $(NAMESPACE)

rollback-frontend: ## Emergency rollback: frontend to previous version
	kubectl rollout undo deployment/frontend -n $(NAMESPACE)

# ─────────────────────────────────────────────────────────────────────────────
# LOAD TESTING
# ─────────────────────────────────────────────────────────────────────────────
smoke: ## Run k6 smoke test (1 VU, 1 min — sanity check)
	k6 run k6/load-tests/smoke-test.js -e BASE_URL=$(BASE_URL)

load-test: ## Run k6 load test (0→50 VUs — HPA validation)
	mkdir -p k6/results
	k6 run k6/load-tests/load-test.js \
		-e BASE_URL=$(BASE_URL) \
		--out json=k6/results/load-$(shell date +%Y%m%d-%H%M).json

stress-test: ## Run k6 stress test (0→200 VUs — breaking point)
	mkdir -p k6/results
	k6 run k6/load-tests/stress-test.js \
		-e BASE_URL=$(BASE_URL) \
		--out json=k6/results/stress-$(shell date +%Y%m%d-%H%M).json

hpa-test: ## Run k6 HPA validation test (baseline + trigger scenarios)
	k6 run k6/load-tests/hpa-validation.js -e BASE_URL=$(BASE_URL)

watch-hpa: ## Watch HPA scaling in real-time (run alongside load tests)
	watch -n 5 'kubectl get hpa,pods -n $(NAMESPACE) && echo "" && kubectl top pods -n $(NAMESPACE)'

# ─────────────────────────────────────────────────────────────────────────────
# MONITORING ACCESS
# ─────────────────────────────────────────────────────────────────────────────
grafana: ## Port-forward Grafana to localhost:3000
	@echo "$(GREEN)Opening Grafana at http://localhost:3000 (admin / ThreeTierPortfolio2024!)$(RESET)"
	kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n $(MONITORING_NS)

prometheus: ## Port-forward Prometheus to localhost:9090
	@echo "$(GREEN)Opening Prometheus at http://localhost:9090$(RESET)"
	kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n $(MONITORING_NS)

alertmanager: ## Port-forward AlertManager to localhost:9093
	kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n $(MONITORING_NS)

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER BUILDS
# ─────────────────────────────────────────────────────────────────────────────
build-backend: ## Build backend Docker image locally
	docker build -t three-tier-backend:local app/backend/

build-frontend: ## Build frontend Docker image locally
	docker build -t three-tier-frontend:local app/frontend/

build-all: build-backend build-frontend ## Build all Docker images

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
clean: ## Clean local build artifacts (node_modules, build dirs, etc.)
	rm -rf app/backend/node_modules
	rm -rf app/frontend/node_modules
	rm -rf app/frontend/build
	rm -rf k6/results/
	@echo "$(GREEN)✓ Build artifacts cleaned$(RESET)"

clean-docker: ## Remove all project Docker images and containers
	docker compose down -v --rmi all
	docker system prune -f
