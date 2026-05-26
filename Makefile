# ─────────────────────────────────────────────────────────────────────────────
# Makefile — Developer Command Center
# ─────────────────────────────────────────────────────────────────────────────
#
# WHAT IS A MAKEFILE?
# -------------------
# A Makefile defines "targets" — short aliases for complex shell commands.
# Instead of remembering long docker/kubectl/terraform commands, you run:
#   make up      → starts the full stack
#   make logs    → tails all container logs
#   make clean   → removes everything including volumes
#
# WHY USE MAKE IN A DEVOPS PROJECT?
# ----------------------------------
# 1. Self-documenting: `make help` shows all commands
# 2. Consistent: every team member runs the same exact commands
# 3. CI/CD integration: GitHub Actions can call `make test`, `make build`
# 4. Reduces cognitive load: no need to remember docker-compose options
#
# USAGE:
#   make <target>
#   make help     → list all available targets
#
# NOTE: Makefile uses TABS (not spaces) for recipe indentation.
# ─────────────────────────────────────────────────────────────────────────────

# Tell make these aren't real files (avoid conflicts with files named 'up', 'down', etc.)
.PHONY: help up down restart logs logs-backend logs-frontend logs-mongo \
        build rebuild shell-backend shell-mongo clean ps health \
        lint test tf-init tf-plan tf-apply

# Default target when you run `make` without arguments
.DEFAULT_GOAL := help

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
COMPOSE_FILE := docker-compose.yml
PROJECT_NAME := three-tier-eks-portfolio

# Colors for terminal output (makes help output readable)
CYAN  := \033[36m
RESET := \033[0m
BOLD  := \033[1m

# ─────────────────────────────────────────────────────────────────────────────
# HELP TARGET
# ─────────────────────────────────────────────────────────────────────────────
help: ## Show this help message
	@echo ""
	@echo "$(BOLD)Three-Tier EKS Portfolio — Developer Commands$(RESET)"
	@echo "=============================================="
	@echo ""
	@echo "$(CYAN)DOCKER COMPOSE:$(RESET)"
	@grep -E '^(up|down|restart|logs|build|rebuild|clean|ps|health):.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(CYAN)DEBUGGING:$(RESET)"
	@grep -E '^(logs-backend|logs-frontend|logs-mongo|shell-backend|shell-mongo):.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(CYAN)QUALITY:$(RESET)"
	@grep -E '^(lint|test):.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(CYAN)TERRAFORM (Day 11+):$(RESET)"
	@grep -E '^(tf-init|tf-plan|tf-apply):.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER COMPOSE COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

up: ## Start all services (build if needed), run in background
	@echo "$(CYAN)Starting three-tier stack...$(RESET)"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) up --build -d
	@echo ""
	@echo "$(BOLD)Services started:$(RESET)"
	@echo "  Frontend:  http://localhost:3000"
	@echo "  Backend:   http://localhost:5000"
	@echo "  Health:    http://localhost:5000/health"
	@echo "  MongoDB:   localhost:27017"
	@echo ""
	@echo "Run $(CYAN)make logs$(RESET) to follow logs"

down: ## Stop and remove all containers (keeps volumes/data)
	@echo "$(CYAN)Stopping three-tier stack...$(RESET)"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) down
	@echo "Containers stopped. Data volumes preserved."
	@echo "Run $(CYAN)make clean$(RESET) to also remove volumes."

restart: ## Restart all services (stops, then starts)
	@$(MAKE) down
	@$(MAKE) up

build: ## Build all Docker images without starting containers
	@echo "$(CYAN)Building all Docker images...$(RESET)"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) build

rebuild: ## Force rebuild all images (ignores cache — use after dependency changes)
	@echo "$(CYAN)Force-rebuilding all Docker images (no cache)...$(RESET)"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) build --no-cache

ps: ## Show status of all running containers
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) ps

health: ## Check health of all services via HTTP
	@echo "$(CYAN)Checking service health...$(RESET)"
	@echo ""
	@echo "Backend /health:"
	@curl -s http://localhost:5000/health | python3 -m json.tool 2>/dev/null || \
		curl -s http://localhost:5000/health
	@echo ""
	@echo "Frontend:"
	@curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:3000

clean: ## Stop containers AND remove volumes (WARNING: deletes all data!)
	@echo "$(CYAN)⚠️  Removing containers and ALL data volumes...$(RESET)"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) down -v --remove-orphans
	@echo "Cleaned. All MongoDB data has been deleted."

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

logs: ## Follow logs from ALL services (Ctrl+C to stop)
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) logs -f

logs-backend: ## Follow logs from backend service only
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) logs -f backend

logs-frontend: ## Follow logs from frontend service only
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) logs -f frontend

logs-mongo: ## Follow logs from MongoDB service only
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) logs -f mongo

# ─────────────────────────────────────────────────────────────────────────────
# DEBUGGING COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

shell-backend: ## Open a shell inside the backend container
	@echo "$(CYAN)Opening shell in backend container...$(RESET)"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) exec backend sh

shell-mongo: ## Open a MongoDB shell (mongosh) inside the mongo container
	@echo "$(CYAN)Opening mongosh in mongo container...$(RESET)"
	@echo "Tip: use 'use tasksdb' then 'db.tasks.find()' to inspect data"
	docker compose -f $(COMPOSE_FILE) -p $(PROJECT_NAME) exec mongo \
		mongosh --username admin --password password123 --authenticationDatabase admin tasksdb

# ─────────────────────────────────────────────────────────────────────────────
# CODE QUALITY
# ─────────────────────────────────────────────────────────────────────────────

lint: ## Run ESLint on backend code
	@echo "$(CYAN)Running ESLint on backend...$(RESET)"
	cd app/backend && npx eslint . --ext .js

test: ## Run backend tests (Jest)
	@echo "$(CYAN)Running backend tests...$(RESET)"
	cd app/backend && npm test

# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM (Placeholder — Day 11+)
# ─────────────────────────────────────────────────────────────────────────────

tf-init: ## Initialize Terraform (downloads providers and modules)
	@echo "$(CYAN)Initializing Terraform...$(RESET)"
	cd terraform && terraform init

tf-plan: ## Preview AWS infrastructure changes
	@echo "$(CYAN)Running Terraform plan...$(RESET)"
	cd terraform && terraform plan -var-file="terraform.tfvars"

tf-apply: ## Apply infrastructure changes (requires confirmation)
	@echo "$(CYAN)Applying Terraform changes...$(RESET)"
	cd terraform && terraform apply -var-file="terraform.tfvars"
