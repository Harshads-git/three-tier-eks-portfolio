# Docker Multi-Stage Build Strategy

## Overview

Both the backend and frontend use **multi-stage Docker builds** — a pattern where one Dockerfile has multiple `FROM` instructions, each defining an isolated build stage. Only the final stage becomes the actual container image.

---

## Why Multi-Stage Builds?

```
Without multi-stage (naive approach):
  FROM node:18
  COPY . .
  RUN npm install
  RUN npm run build
  CMD ["node", "index.js"]
  → Image size: ~950 MB ❌

With multi-stage:
  Stage 1 (build): node:18-alpine → compile/install
  Stage 2 (runtime): nginx:alpine or node:18-alpine → just what's needed to run
  → Backend image:  ~90 MB ✅
  → Frontend image: ~22 MB ✅
```

**Impact on Kubernetes:**
- 10x smaller image = pod startup is 10x faster
- Less ECR storage cost
- Smaller attack surface (fewer packages = fewer CVEs)
- Faster CI/CD pipeline (push/pull in seconds, not minutes)

---

## Backend Dockerfile — Two-Stage Pattern

```
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 1: deps (node:18-alpine)                                      │
│  ─────────────────────────────                                        │
│  COPY package.json package-lock.json                                 │
│  RUN npm ci --omit=dev    ← installs ONLY production dependencies    │
│                                                                       │
│  Result: /app/node_modules (prod deps only, ~60MB)                   │
└─────────────────────┬───────────────────────────────────────────────┘
                      │ COPY --from=deps /app/node_modules
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 2: runtime (node:18-alpine)            FINAL IMAGE            │
│  ─────────────────────────────────────────                           │
│  RUN addgroup/adduser nodejs (non-root user)                         │
│  ENV NODE_ENV=production PORT=5000                                   │
│  COPY --from=deps node_modules/ (prod deps)                          │
│  COPY source code (db.js, index.js, models/, routes/)               │
│  USER nodejs  ← switches to non-root                                 │
│  HEALTHCHECK /health                                                 │
│  CMD ["node", "index.js"]                                            │
│                                                                       │
│  Result: ~90MB image, non-root, no devDeps, no npm cache             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Frontend Dockerfile — Two-Stage Pattern

```
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 1: builder (node:18-alpine)                                   │
│  ─────────────────────────────────                                   │
│  ARG REACT_APP_BACKEND_URL   ← build-time variable (baked in!)       │
│  ENV REACT_APP_BACKEND_URL=${REACT_APP_BACKEND_URL}                  │
│  COPY package.json package-lock.json                                 │
│  RUN npm ci  (includes devDeps like react-scripts)                   │
│  COPY source code (src/, public/)                                    │
│  RUN npm run build  ← webpack bundles React → build/                 │
│                                                                       │
│  Result: /app/build/ directory (~2MB of HTML/CSS/JS)                 │
└─────────────────────┬───────────────────────────────────────────────┘
                      │ COPY --from=builder /app/build /usr/share/nginx/html
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 2: runtime (nginx:1.25-alpine)         FINAL IMAGE            │
│  ───────────────────────────────────                                 │
│  COPY nginx.conf /etc/nginx/nginx.conf                               │
│  COPY build/ output from stage 1                                     │
│  HEALTHCHECK /nginx-health                                           │
│  CMD ["nginx", "-g", "daemon off;"]                                  │
│                                                                       │
│  Result: ~22MB image, no Node.js, no npm, pure static file serving   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Docker Layer Caching — The Most Important Build Optimization

Docker caches each layer (RUN/COPY instruction). If the input hasn't changed, Docker reuses the cached layer — skipping that step entirely.

```dockerfile
# WRONG ORDER — breaks caching:
COPY . .                 # Source code changes on every commit
RUN npm ci               # npm ci runs on EVERY build (30-60 seconds wasted!)

# CORRECT ORDER — optimal caching:
COPY package.json package-lock.json ./   # Changes rarely (only when adding packages)
RUN npm ci                               # CACHED on most builds (instant)
COPY . .                                 # Source code copied (always runs, but fast)
```

**Real-world impact:**
- First build: 90 seconds (npm ci + build)
- Subsequent builds (code only): 15 seconds (npm ci cached!)
- On package.json change: 90 seconds again (cache busted)

---

## Security Practices Applied

| Practice | Backend | Frontend | Why |
|---|---|---|---|
| **Pinned base image version** | `node:18-alpine` | `nginx:1.25-alpine` | Reproducible builds — no surprise breakage |
| **Alpine Linux** | ✅ | ✅ | 5MB base, minimal attack surface |
| **Non-root user** | `nodejs:nodejs` (UID 1000) | `nginx` (worker process) | Limits container compromise blast radius |
| **npm ci** | ✅ | ✅ | Reproducible, exact-version installs |
| **No devDependencies in runtime** | `--omit=dev` in Stage 1 | N/A (Nginx stage, no Node.js) | Smaller image, no test frameworks in prod |
| **HEALTHCHECK instruction** | `/health` endpoint | `/nginx-health` | Docker health gating |
| **JSON array CMD** | `["node", "index.js"]` | `["nginx", "-g", "daemon off;"]` | PID 1 receives SIGTERM → graceful shutdown |
| **OCI labels** | ✅ | ✅ | Traceability in ECR, audit trail |

---

## Nginx Configuration Key Features

```nginx
# 1. SPA ROUTING — The most critical setting for React
location / {
    try_files $uri $uri/ /index.html;
    # Explanation:
    # $uri     → Try exact file (e.g., /static/js/main.js → serve it)
    # $uri/    → Try as directory
    # /index.html → Fallback for any path React Router handles (/tasks, /about)
    # Without this: navigating to /tasks returns 404 from Nginx!
}

# 2. LONG-TERM CACHING for hashed assets
location ~* \.(js|css|png|ico)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    # React's build hashes filenames: main.abc123.js
    # New deployment → new hash → browser fetches fresh copy
    # Old deployment → same hash → browser uses cache (zero network cost!)
}

# 3. GZIP compression
gzip on;  # ~300KB JS bundle → ~80KB gzip (73% reduction!)
```

---

## REACT_APP_BACKEND_URL — Build-Time Variable Flow

```
GitHub Actions CI/CD                       Local Development
──────────────────────────────────         ──────────────────────────────
1. Get ALB DNS from Terraform output       1. Set in .env.docker or inline:
   ALB_DNS=$(terraform output alb_dns)        REACT_APP_BACKEND_URL=http://localhost:5000/api/tasks

2. docker build \                          2. docker compose up --build
     --build-arg REACT_APP_BACKEND_URL=       (compose passes arg from docker-compose.yml)
       http://${ALB_DNS}/api/tasks \
     ...

3. webpack reads process.env.REACT_APP_BACKEND_URL
   during `npm run build` inside Dockerfile Stage 1

4. Value is compiled into:
   build/static/js/main.abc123.js
   (axios calls in taskServices.js now use the baked-in URL)

5. Image pushed to ECR → deployed to EKS pods
   → React app calls the correct ALB endpoint
```

> ⚠️ **Critical**: If you change the backend URL after building the image, you MUST rebuild the frontend image. The URL is NOT a runtime variable — it's a compile-time constant.

---

## Image Size Breakdown

| Layer | Backend | Frontend |
|---|---|---|
| Base OS (Alpine) | ~5 MB | ~5 MB |
| Node.js runtime | ~55 MB | N/A |
| Nginx binary | N/A | ~10 MB |
| node_modules (prod) | ~25 MB | N/A |
| Application code | ~1 MB | N/A |
| React build output | N/A | ~2 MB |
| **Total** | **~86 MB** | **~17 MB** |

---

## Building Images Manually

```bash
# Backend
docker build \
  --platform linux/amd64 \
  --tag three-tier-backend:local \
  app/backend/

# Frontend
docker build \
  --platform linux/amd64 \
  --build-arg REACT_APP_BACKEND_URL=http://localhost:5000/api/tasks \
  --tag three-tier-frontend:local \
  app/frontend/

# Test backend image
docker run --rm -p 5000:5000 \
  -e MONGO_URI="mongodb://localhost:27017/tasksdb" \
  three-tier-backend:local

# Test frontend image (Nginx)
docker run --rm -p 3000:80 three-tier-frontend:local
```

---

## ECR Push Workflow (Manual — until Day 24 CI/CD)

```bash
# See scripts/build-and-push.sh for the full workflow
export AWS_ACCOUNT_ID=123456789012
export AWS_REGION=us-east-1
export IMAGE_TAG=$(git rev-parse --short HEAD)
export REACT_APP_BACKEND_URL=http://<ALB-DNS>/api/tasks

./scripts/build-and-push.sh
```

---

## Trivy Security Scan (Preview — Day 24)

```bash
# Scan backend image for CVEs
trivy image --severity HIGH,CRITICAL three-tier-backend:local

# Scan frontend image
trivy image --severity HIGH,CRITICAL three-tier-frontend:local

# In CI/CD (Day 24): fail the pipeline if critical CVEs found
trivy image --exit-code 1 --severity CRITICAL three-tier-backend:local
```
