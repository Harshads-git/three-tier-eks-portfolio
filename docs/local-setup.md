# Local Development Setup Guide

This guide explains how to run the complete Three-Tier application locally using Docker Compose.

---

## Prerequisites

| Tool | Minimum Version | Check Command | Install |
|---|---|---|---|
| **Docker Desktop** | 24.x | `docker --version` | [docs.docker.com](https://docs.docker.com/get-docker/) |
| **Docker Compose** | v2 (built-in) | `docker compose version` | Bundled with Docker Desktop |
| **Git** | 2.x | `git --version` | [git-scm.com](https://git-scm.com/) |
| **Make** | 3.8+ | `make --version` | macOS: `xcode-select --install` / Linux: `apt install make` |
| **curl** | any | `curl --version` | Pre-installed on most systems |

> **Windows users:** Use Git Bash, WSL2, or PowerShell with the `make` equivalent commands shown below.

---

## Quick Start (3 Commands)

```bash
# 1. Clone the repository
git clone https://github.com/Harshads-git/three-tier-eks-portfolio.git
cd three-tier-eks-portfolio

# 2. Start all 3 tiers
make up

# 3. Access the app
open http://localhost:3000
```

That's it! All three services start automatically.

---

## What `make up` Does

`make up` runs `docker compose up -d --build`, which:

```
Step 1: Builds the Docker images (if they don't exist or changed)
        ├── mongo    → pulls mongo:6.0 from Docker Hub
        ├── backend  → builds Node.js image from app/backend/Dockerfile
        └── frontend → builds Nginx/React image from app/frontend/Dockerfile

Step 2: Creates the Docker network
        └── three-tier-network (bridge) — isolated network for inter-service comms

Step 3: Starts containers in dependency order
        1. mongo     → starts first (backend depends on it)
        2. backend   → waits for mongo health check to pass
        3. frontend  → starts after backend

Step 4: Returns control to terminal (detached mode -d)
```

**First run:** Takes 3-5 minutes (building images, pulling base images).
**Subsequent runs:** Takes 10-30 seconds (using cached layers).

---

## Access Points

| Service | URL | Description |
|---|---|---|
| **Frontend** | http://localhost:3000 | React To-Do application (Nginx served) |
| **Backend API** | http://localhost:5000/api/tasks | REST API (direct access) |
| **Health Check** | http://localhost:5000/health | Backend health + MongoDB status |
| **MongoDB** | `localhost:27017` | Database (for MongoDB Compass / mongosh) |

---

## Service Architecture (Local)

```
Your Browser
     │
     ├──── GET http://localhost:3000  ─────────────► frontend container (Nginx:80)
     │                                               └── Serves React build/ files
     │                                               └── Passes API calls through
     │
     └──── GET http://localhost:5000/api/tasks ─────► backend container (Node:5000)
                                                       └── Express REST API
                                                       └── Connects to mongo container
                                                           via Docker DNS: mongodb://mongo:27017

     Docker Network (three-tier-network):
     ┌─────────────────────────────────────────────┐
     │  frontend ─────────────────► backend        │
     │                              │              │
     │                              ▼              │
     │                           mongo             │
     │                         (volume: mongo-data)│
     └─────────────────────────────────────────────┘
```

---

## Common Commands

### Start / Stop

```bash
make up         # Start all services (builds if needed)
make down       # Stop all services (data preserved)
make restart    # Stop then start (shortcut for down + up)
make build      # Rebuild images without Docker cache
```

### Logs

```bash
make logs            # Tail ALL service logs
make logs-backend    # Backend (Node.js) logs only
make logs-frontend   # Frontend (Nginx) logs only
make logs-mongo      # MongoDB logs only
```

### Shell Access (Debug inside containers)

```bash
make shell-backend   # /bin/sh inside backend container
make shell-frontend  # /bin/sh inside frontend (Nginx) container
make shell-mongo     # mongosh CLI inside MongoDB container
```

### API Smoke Tests

```bash
make health     # Call GET /health and display JSON output
make test-api   # Run GET, POST tests against the API
make db-seed    # Seed 5 sample tasks into MongoDB
```

### Cleanup

```bash
make clean      # Stop + delete volumes (WARNING: deletes MongoDB data)
make nuke       # Remove containers, images, volumes, networks (full reset)
```

---

## Verifying Each Service

### 1. Verify MongoDB is Running

```bash
# Check container status
docker compose ps

# Connect with mongosh
make shell-mongo
# Inside mongosh:
> show dbs
> use tasksdb
> db.tasks.find().pretty()
```

### 2. Verify Backend is Running

```bash
# Health check
curl http://localhost:5000/health

# Expected response:
{
  "status": "ok",
  "timestamp": "2026-05-26T...",
  "uptime": 42,
  "checks": {
    "mongodb": { "status": "connected", ... },
    "memory": { ... }
  }
}
```

### 3. Verify the Full API

```bash
# Get all tasks (should be empty array initially)
curl http://localhost:5000/api/tasks

# Create a task
curl -X POST http://localhost:5000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"task": "Test the local Docker Compose setup"}'

# Get all tasks again (should have 1 task now)
curl http://localhost:5000/api/tasks
```

### 4. Verify Frontend

Open http://localhost:3000 in your browser. You should see the To-Do application.

- Add a task → it should appear in the list
- Check the checkbox → task should get a strikethrough
- Click Delete → task should disappear

---

## Troubleshooting

### Problem: `make up` fails — port already in use

```
Error: Bind for 0.0.0.0:3000 failed: port is already allocated
```

**Fix:** Something else is using that port. Kill it or change the port mapping in `docker-compose.yml`.

```bash
# Find what's using port 3000 (macOS/Linux)
lsof -i :3000

# Find what's using port 3000 (Windows)
netstat -ano | findstr :3000
```

---

### Problem: Backend fails to connect to MongoDB

```
[db.js] ❌ MongoDB connection failed: connect ECONNREFUSED 127.0.0.1:27017
```

**Cause:** MongoDB container is not yet healthy (or service name is wrong).

**Fix:**
```bash
# Check MongoDB health
docker compose ps
# If mongo shows "(health: starting)", wait and retry

# Check MongoDB logs
make logs-mongo
```

> This is exactly why `depends_on: condition: service_healthy` exists in `docker-compose.yml`.
> The backend waits for MongoDB's health check to pass before starting.

---

### Problem: Frontend shows blank page or API calls fail

**Cause:** `REACT_APP_BACKEND_URL` was not set correctly at build time.

**Fix:**
```bash
# Verify the build arg was injected
docker compose exec frontend cat /usr/share/nginx/html/static/js/main.*.js | grep -o 'localhost:5000' | head -1

# If not found, rebuild with no cache
make build
```

> Remember: React env vars are baked in at build time. Changing `docker-compose.yml`
> build args requires a `make build` to take effect.

---

### Problem: MongoDB data is lost after restart

```bash
# Check if the volume exists
docker volume ls | grep mongo

# If missing, the volume was deleted (docker compose down -v was run)
# Just run make up again — MongoDB will start fresh with an empty database
make up
make db-seed  # Reseed with sample data
```

---

## How This Maps to Kubernetes

Understanding the Docker Compose setup is the foundation for understanding the EKS deployment:

| Docker Compose Concept | Kubernetes Equivalent |
|---|---|
| `services:` | Pod definitions in Deployments/StatefulSets |
| `image:` | `spec.containers[].image` from ECR |
| `build:` | GitHub Actions builds image → pushes to ECR |
| `ports:` (host) | Kubernetes Ingress (ALB) |
| `ports:` (container) | `spec.containers[].ports[].containerPort` |
| `environment:` | ConfigMap + Secret (`env[].valueFrom`) |
| `depends_on:` | initContainers or readinessProbe |
| `networks:` | Kubernetes Services (ClusterIP) |
| `volumes:` (named) | PersistentVolumeClaim (EBS gp2) |
| `healthcheck:` | `livenessProbe` + `readinessProbe` |
| `restart: unless-stopped` | `restartPolicy: Always` |

---

## Environment Variable Reference

### Backend (app/backend/.env.docker)

| Variable | Value | K8s Source |
|---|---|---|
| `PORT` | `5000` | ConfigMap |
| `NODE_ENV` | `development` | ConfigMap |
| `MONGO_URI` | `mongodb://admin:password123@mongo:27017/tasksdb?authSource=admin` | Secret |

### Frontend (app/frontend/.env.docker — build arg)

| Variable | Value | K8s Source |
|---|---|---|
| `REACT_APP_BACKEND_URL` | `http://localhost:5000/api/tasks` | `--build-arg` in CI/CD |

> **Why `localhost:5000` for frontend?**
> The React JS bundle runs **in the user's browser** (not inside Docker).
> The browser cannot resolve Docker service names like `backend`.
> It can only reach services exposed on the host machine via mapped ports.
