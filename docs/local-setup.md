# Local Development Setup Guide

## Overview

This guide explains how to run the full three-tier application locally using **Docker Compose** — with all three tiers (Frontend, Backend, MongoDB) running as containers on your machine with a single command.

> **No AWS account needed** for local development. All three tiers run entirely on your local machine.

---

## Prerequisites

| Tool | Minimum Version | Check |
|---|---|---|
| Docker Desktop | 24.x | `docker --version` |
| Docker Compose | v2.x (included with Desktop) | `docker compose version` |
| Git | Any | `git --version` |
| Make | Any | `make --version` |

> **Windows**: Install Make via [winget](https://winget.run/pkg/GnuWin32/Make): `winget install GnuWin32.Make`

---

## Quick Start (3 Commands)

```bash
# 1. Clone the repository
git clone https://github.com/Harshads-git/three-tier-eks-portfolio.git
cd three-tier-eks-portfolio

# 2. Start the full stack
make up

# 3. Open the app
# Browser: http://localhost:3000
```

---

## What Happens When You Run `make up`

```
make up
  │
  ▼ docker compose up --build -d
  │
  ├── STEP 1: Builds Docker images
  │     ├── mongo:6.0         → pulled from Docker Hub (no build needed)
  │     ├── backend image     → built from app/backend/Dockerfile
  │     └── frontend image    → built from app/frontend/Dockerfile (multi-stage)
  │
  ├── STEP 2: Creates resources
  │     ├── Network: three-tier-network  (isolated bridge network)
  │     └── Volume:  mongo-data          (named volume for MongoDB data)
  │
  ├── STEP 3: Starts containers in dependency order
  │     ├── 1st: mongo    (starts, waits for healthcheck to pass)
  │     ├── 2nd: backend  (starts after mongo is healthy)
  │     └── 3rd: frontend (starts after backend is healthy)
  │
  └── STEP 4: Containers run in background (-d flag)
```

---

## Service Access Points

| Service | URL | Purpose |
|---|---|---|
| **Frontend** | http://localhost:3000 | React To-Do application (Nginx) |
| **Backend API** | http://localhost:5000/api/tasks | REST API (GET tasks) |
| **Health Check** | http://localhost:5000/health | Backend + MongoDB status |
| **MongoDB** | `localhost:27017` | Direct DB access (dev only) |

---

## All Available Commands

```bash
make help           # List all available commands

# Stack management
make up             # Start all services (build if needed)
make down           # Stop all containers (data preserved)
make restart        # Stop then start
make build          # Build images without starting
make rebuild        # Force rebuild (no cache — after npm package changes)

# Monitoring
make ps             # Show container status
make health         # HTTP health check all services
make logs           # Follow logs from ALL containers (Ctrl+C to stop)
make logs-backend   # Backend logs only
make logs-frontend  # Frontend (Nginx) logs only
make logs-mongo     # MongoDB logs only

# Debugging
make shell-backend  # Open sh shell in backend container
make shell-mongo    # Open mongosh in MongoDB container

# Quality
make lint           # Run ESLint on backend
make test           # Run Jest tests on backend
```

---

## Container Architecture (Local)

```
Your Browser (localhost)
        │
        │ http://localhost:3000
        ▼
┌──────────────────────────────────────────────────────────────────┐
│              Docker Bridge Network: three-tier-network            │
│                                                                    │
│  ┌─────────────────────┐     ┌─────────────────────────────────┐  │
│  │   frontend:80        │     │   backend:5000                   │  │
│  │   (Nginx)            │────▶│   (Node.js/Express)             │  │
│  │   React static build │     │   REST API /api/tasks           │  │
│  └─────────────────────┘     └──────────────┬──────────────────┘  │
│   Host port: 3000                            │ mongoose            │
│                               ┌──────────────▼──────────────────┐  │
│                               │   mongo:27017                    │  │
│                               │   MongoDB 6.0                    │  │
│                               │   Data: mongo-data volume        │  │
│                               └─────────────────────────────────┘  │
│                                Host port: 27017                     │
└──────────────────────────────────────────────────────────────────┘
```

---

## Environment Variables

| Variable | Service | Value (Local) | K8s Equivalent |
|---|---|---|---|
| `MONGO_INITDB_ROOT_USERNAME` | mongo | `admin` | K8s Secret |
| `MONGO_INITDB_ROOT_PASSWORD` | mongo | `password123` | K8s Secret |
| `MONGO_URI` | backend | `mongodb://admin:password123@mongo:27017/tasksdb` | K8s Secret |
| `PORT` | backend | `5000` | K8s ConfigMap |
| `NODE_ENV` | backend | `development` | K8s ConfigMap |
| `REACT_APP_BACKEND_URL` | frontend | `http://localhost:5000/api/tasks` | Docker `--build-arg` |

> **Key Insight**: In Docker Compose, `mongo` in the `MONGO_URI` is the **service name** — Docker's internal DNS resolves it to the MongoDB container's IP. This is identical to how Kubernetes Service DNS works.

---

## Verifying Everything Works

### 1. Check containers are running
```bash
make ps
# Expected output:
# NAME                    STATUS
# three-tier-frontend     running (healthy)
# three-tier-backend      running (healthy)
# three-tier-mongo        running (healthy)
```

### 2. Test the backend directly
```bash
# Get all tasks (should return [] on fresh start)
curl http://localhost:5000/api/tasks

# Create a task
curl -X POST http://localhost:5000/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"task": "Learn Kubernetes"}'

# Check health (MongoDB connection status)
curl http://localhost:5000/health
```

### 3. Open the frontend
Navigate to **http://localhost:3000** and add a task. It should:
1. Appear instantly in the list (React state update)
2. Survive a browser refresh (persisted in MongoDB)
3. Survive a `make restart` (data in named Docker volume)

### 4. Inspect MongoDB directly
```bash
make shell-mongo
# Inside mongosh:
use tasksdb
db.tasks.find().pretty()
```

---

## Common Issues & Fixes

| Issue | Symptom | Fix |
|---|---|---|
| Port already in use | `Error: address already in use: 5000` | `lsof -i :5000` then kill the process |
| Docker Desktop not running | `Cannot connect to Docker daemon` | Start Docker Desktop |
| Backend can't reach MongoDB | `MongoServerSelectionError` in logs | `make logs-mongo` — wait for `Waiting for connections` message |
| Frontend shows blank page | White screen, no tasks | Check `make logs-frontend` for Nginx errors |
| Changes not reflected | Old code still running | `make rebuild` to force rebuild without cache |
| MongoDB data corrupted | Container exits immediately | `make clean` (⚠️ deletes all data), then `make up` |

---

## Stopping the Stack

```bash
# Stop containers (data PRESERVED in named volumes)
make down

# Stop AND delete all data (fresh start)
make clean
```

---

## How This Compares to Kubernetes

| Concern | Docker Compose (Local) | Kubernetes EKS (Production) |
|---|---|---|
| Service discovery | Docker DNS (`mongo`, `backend`) | K8s DNS (`mongo-service.namespace.svc.cluster.local`) |
| Secrets | Plain text in env / .env.docker | K8s Secret (base64) → AWS Secrets Manager (encrypted) |
| Persistence | Named Docker volume | EBS PersistentVolumeClaim |
| Health checks | `healthcheck:` in compose | `livenessProbe` / `readinessProbe` |
| Scaling | N/A (single instance) | HorizontalPodAutoscaler |
| Load balancing | N/A | AWS Application Load Balancer |
| Restart policy | `unless-stopped` | `restartPolicy: Always` |
| Startup order | `depends_on: condition: service_healthy` | K8s init containers or retry logic |

---

## Next Steps

After confirming local setup works, Day 5 covers the **MongoDB Kubernetes manifests** and Day 6 starts **Dockerizing** both tiers for ECR.
