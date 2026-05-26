# ─────────────────────────────────────────────────────────────────────────────
# Makefile — Developer Convenience Commands
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT IS A MAKEFILE?
# -------------------
# A Makefile is a build automation tool that defines named "targets" (tasks).
# Run any target with: make <target>
# Example: make up, make logs, make clean
#
# WHY USE MAKE IN A DEVOPS PROJECT?
# -----------------------------------
# 1. Single interface: Developers don't need to remember long docker/kubectl/
#    terraform commands — just `make <target>`
# 2. Documentation: The Makefile IS the documentation for common operations
# 3. Automation: CI/CD pipelines can call `make build`, `make test`, etc.
# 4. Portability: Works on Linux, macOS, and Windows (WSL/Git Bash)
#
# HOW MAKE TARGETS WORK:
# ----------------------
# target-name: dependency1 dependency2   ← dependencies (optional)
# [TAB] command to run                   ← MUST be a real TAB character, not spaces
#
# .PHONY tells make these are NOT file names (prevents conflicts with same-named files)
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: help up down restart logs logs-backend logs-frontend logs-mongo \
        shell-backend shell-frontend shell-mongo build clean nuke \
        status health test-api

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULT TARGET — shown when running just `make`
# ─────────────────────────────────────────────────────────────────────────────
# The first target is the default. We make it `help` so `make` shows usage.

help: ## Show this help message
	@echo ""
	@echo "  ╔══════════════════════════════════════════════════════════╗"
	@echo "  ║     Three-Tier EKS Portfolio — Developer Commands        ║"
	@echo "  ╚══════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  Local Development:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Access Points (after make up):"
	@echo "    Frontend:   http://localhost:3000"
	@echo "    Backend:    http://localhost:5000"
	@echo "    Health:     http://localhost:5000/health"
	@echo "    MongoDB:    mongodb://admin:password123@localhost:27017/tasksdb"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER COMPOSE LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

up: ## Start all 3 services in detached mode (builds images if needed)
	@echo "🚀 Starting Three-Tier application..."
	docker compose up -d --build
	@echo ""
	@echo "✅ All services started!"
	@echo "   Frontend:  http://localhost:3000"
	@echo "   Backend:   http://localhost:5000"
	@echo "   Health:    http://localhost:5000/health"
	@echo ""
	@echo "   Run 'make logs' to tail all logs"

down: ## Stop and remove all containers (keeps volumes — data preserved)
	@echo "🛑 Stopping Three-Tier application..."
	docker compose down
	@echo "✅ All containers stopped. Data volumes preserved."

restart: down up ## Restart all services (stop + start)

build: ## Rebuild all images without cache (use after Dockerfile changes)
	@echo "🔨 Rebuilding all Docker images (no cache)..."
	docker compose build --no-cache

# ─────────────────────────────────────────────────────────────────────────────
# LOGS
# ─────────────────────────────────────────────────────────────────────────────

logs: ## Tail logs from ALL services
	docker compose logs -f

logs-backend: ## Tail logs from backend (Node.js) only
	docker compose logs -f backend

logs-frontend: ## Tail logs from frontend (Nginx) only
	docker compose logs -f frontend

logs-mongo: ## Tail logs from MongoDB only
	docker compose logs -f mongo

# ─────────────────────────────────────────────────────────────────────────────
# SHELL ACCESS (Exec into running containers — mirrors kubectl exec)
# ─────────────────────────────────────────────────────────────────────────────
# K8s equivalent: kubectl exec -it <pod-name> -n three-tier -- /bin/sh

shell-backend: ## Open a shell inside the running backend container
	docker compose exec backend /bin/sh

shell-frontend: ## Open a shell inside the running frontend (Nginx) container
	docker compose exec frontend /bin/sh

shell-mongo: ## Open mongosh inside the running MongoDB container
	docker compose exec mongo mongosh -u admin -p password123 --authenticationDatabase admin tasksdb

# ─────────────────────────────────────────────────────────────────────────────
# STATUS & HEALTH
# ─────────────────────────────────────────────────────────────────────────────

status: ## Show status of all running containers
	@echo "📊 Container Status:"
	docker compose ps

health: ## Check backend health endpoint
	@echo "🏥 Checking backend health..."
	@curl -s http://localhost:5000/health | python3 -m json.tool 2>/dev/null || \
	 curl -s http://localhost:5000/health

# ─────────────────────────────────────────────────────────────────────────────
# API TESTING (Quick smoke tests without a test framework)
# ─────────────────────────────────────────────────────────────────────────────

test-api: ## Run basic API smoke tests against the running backend
	@echo "🧪 Running API smoke tests..."
	@echo ""
	@echo "--- GET /health ---"
	@curl -sf http://localhost:5000/health | python3 -m json.tool || echo "FAILED"
	@echo ""
	@echo "--- GET /api/tasks ---"
	@curl -sf http://localhost:5000/api/tasks | python3 -m json.tool || echo "FAILED"
	@echo ""
	@echo "--- POST /api/tasks ---"
	@curl -sf -X POST http://localhost:5000/api/tasks \
	  -H "Content-Type: application/json" \
	  -d '{"task":"Test task from Makefile smoke test"}' | python3 -m json.tool || echo "FAILED"
	@echo ""
	@echo "✅ Smoke tests complete. Check output above for errors."

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────────────────────────

clean: ## Stop containers AND remove volumes (WARNING: deletes MongoDB data!)
	@echo "⚠️  This will DELETE all MongoDB data in the local volume!"
	@echo "   Press Ctrl+C to cancel, or wait 5 seconds to continue..."
	@sleep 5
	docker compose down -v
	@echo "✅ Containers and volumes removed."

nuke: ## Remove ALL Docker resources: containers, images, volumes, networks
	@echo "💣 Removing ALL Docker resources for this project..."
	docker compose down -v --rmi all --remove-orphans
	@echo "✅ Full cleanup complete. Run 'make up' to start fresh."

# ─────────────────────────────────────────────────────────────────────────────
# INDIVIDUAL SERVICE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

db-seed: ## Seed MongoDB with sample tasks (useful for UI development)
	@echo "🌱 Seeding database with sample tasks..."
	@curl -sf -X POST http://localhost:5000/api/tasks \
	  -H "Content-Type: application/json" \
	  -d '{"task":"Set up EKS cluster with Terraform"}' > /dev/null
	@curl -sf -X POST http://localhost:5000/api/tasks \
	  -H "Content-Type: application/json" \
	  -d '{"task":"Configure IRSA for Load Balancer Controller"}' > /dev/null
	@curl -sf -X POST http://localhost:5000/api/tasks \
	  -H "Content-Type: application/json" \
	  -d '{"task":"Deploy Prometheus and Grafana monitoring stack"}' > /dev/null
	@curl -sf -X POST http://localhost:5000/api/tasks \
	  -H "Content-Type: application/json" \
	  -d '{"task":"Write GitHub Actions CI/CD pipeline"}' > /dev/null
	@curl -sf -X POST http://localhost:5000/api/tasks \
	  -H "Content-Type: application/json" \
	  -d '{"task":"Set up Cluster Autoscaler and HPA"}' > /dev/null
	@echo "✅ 5 sample tasks added. Open http://localhost:3000 to view them."
