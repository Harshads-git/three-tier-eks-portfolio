# ─────────────────────────────────────────────────────────────────────────────
# app/backend/Dockerfile — Production-Grade Multi-Stage Backend Image
# ─────────────────────────────────────────────────────────────────────────────
#
# MULTI-STAGE BUILD EXPLAINED:
# ─────────────────────────────────────────────────────────────────────────────
# A multi-stage build uses MULTIPLE FROM instructions. Each FROM starts a
# new "stage" with its own filesystem. You selectively COPY artifacts from
# earlier stages into later ones.
#
# For a Node.js backend, we technically don't need 2 stages (unlike frontend
# which compiles React). However we still use a build stage pattern because:
#   1. We can run npm ci with dev dependencies (for tests/linting in CI)
#   2. We only COPY node_modules from production deps into the runtime image
#   3. The final image is smaller (no devDependencies, no npm cache)
#
# IMAGE SIZE COMPARISON:
#   node:18                   → ~950 MB (full Debian + all tools)
#   node:18-alpine            → ~170 MB (Alpine Linux, minimal tools)
#   Our final image (alpine)  → ~90 MB  (only production deps + source)
#
# WHY ALPINE?
#   Alpine Linux is a minimal distribution (5MB base). It has:
#   ✅ Smaller attack surface (fewer packages = fewer CVEs)
#   ✅ Faster pull times in Kubernetes (smaller image = faster pod startup)
#   ✅ Less storage cost in ECR (smaller image = less storage)
#   ❌ Uses musl libc (not glibc) — some native modules may not compile
#      (Not an issue for express/mongoose — they have no native addons)
#
# SECURITY PRACTICES IN THIS DOCKERFILE:
#   1. Non-root user (nodejs:nodejs) — container never runs as root
#   2. Read-only source code files (--chown)
#   3. Pinned base image version (node:18-alpine, not node:latest)
#   4. npm ci (reproducible, exact-version installs from package-lock.json)
#   5. NODE_ENV=production (prevents devDependencies install at runtime)
#   6. Only production node_modules in final image
# ─────────────────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1: DEPENDENCY INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════
# Purpose: Install ALL dependencies (including devDeps for future CI use).
# We'll only COPY the production deps into Stage 2.
#
# "AS deps" names this stage so we can reference it in COPY --from=deps
FROM node:18-alpine AS deps

# WORKDIR: Sets the working directory inside the container.
# All subsequent COPY, RUN, CMD instructions are relative to /app.
# Creates /app if it doesn't exist.
# Best practice: Use /app (not /home/node/app or similar — /app is conventional)
WORKDIR /app

# COPY package files BEFORE copying source code.
# WHY? Docker layer caching:
#   - Each RUN/COPY instruction creates a new image layer
#   - Docker caches layers and reuses them if the input hasn't changed
#   - package.json + package-lock.json change RARELY (only when adding packages)
#   - Source code changes FREQUENTLY (every code edit)
#   - By copying package files first, `npm ci` (expensive) is CACHED
#   - Only the COPY source code layer is re-run on code changes
#   - This makes subsequent builds 10x faster
COPY package.json package-lock.json ./

# npm ci (Clean Install) vs npm install:
#   npm ci:
#     ✅ Uses EXACT versions from package-lock.json (reproducible builds)
#     ✅ Fails if package-lock.json is out of sync with package.json
#     ✅ Always deletes node_modules before installing (clean slate)
#     ✅ Faster in CI (no dependency resolution)
#   npm install:
#     ❌ May update package-lock.json (non-deterministic in CI)
#     ❌ Resolves dependencies on every run (slower)
#
# --omit=dev: Install only production dependencies (not jest, nodemon, etc.)
# In Stage 1 we install prod deps. If you need dev deps for tests, add a
# separate stage: npm ci (all deps) → run tests → COPY only prod node_modules
RUN npm ci --omit=dev

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2: PRODUCTION RUNTIME
# ═════════════════════════════════════════════════════════════════════════════
# This is the FINAL image — what gets pushed to ECR and runs in Kubernetes.
# It contains ONLY what's needed to run the app (no build tools, no dev deps).
FROM node:18-alpine AS runtime

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY: Create non-root user
# ─────────────────────────────────────────────────────────────────────────────
# By default, Docker containers run as root (UID 0). This is dangerous:
#   - If the app is compromised, the attacker has full root access to the container
#   - With --privileged or host mounts, root container = root on host
#
# Best practice: Create a dedicated non-root user for the application.
# node:18-alpine already has a 'node' user (UID 1000) — we use it.
#
# addgroup -S nodejs: Creates system group 'nodejs' (-S = system, no home dir)
# adduser -S -G nodejs nodejs: Creates system user 'nodejs' in group 'nodejs'
RUN addgroup -S nodejs && adduser -S -G nodejs nodejs

# Metadata labels — best practice for traceability in production.
# Visible via: docker inspect <image> | grep Labels
# In ECR, these appear as image metadata.
LABEL maintainer="Harshads-git" \
      org.opencontainers.image.source="https://github.com/Harshads-git/three-tier-eks-portfolio" \
      org.opencontainers.image.description="Three-Tier Backend — Node.js/Express REST API" \
      org.opencontainers.image.version="1.0.0"

# ─────────────────────────────────────────────────────────────────────────────
# ENVIRONMENT VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
# NODE_ENV=production:
#   1. Express disables development features (stack traces in responses)
#   2. npm (if run) skips devDependencies
#   3. Express is ~3x faster in production mode (no reloads, cached views)
#
# PORT: Default port. Overridden by K8s ConfigMap at runtime.
ENV NODE_ENV=production \
    PORT=5000

WORKDIR /app

# ─────────────────────────────────────────────────────────────────────────────
# COPY FROM STAGE 1 — Production node_modules only
# ─────────────────────────────────────────────────────────────────────────────
# COPY --from=deps: Pulls files from the "deps" stage (not from host filesystem).
# We only copy node_modules (production deps) — NOT the entire stage 1 image.
# This is the key to multi-stage efficiency.
#
# --chown=nodejs:nodejs: Sets file ownership to our non-root user.
# Without this, files are owned by root even inside the container.
COPY --from=deps --chown=nodejs:nodejs /app/node_modules ./node_modules

# ─────────────────────────────────────────────────────────────────────────────
# COPY APPLICATION SOURCE CODE
# ─────────────────────────────────────────────────────────────────────────────
# Copy source files from the build context (host machine).
# .dockerignore ensures node_modules, .env, tests are NOT copied.
# See: app/backend/.dockerignore for excluded files.
COPY --chown=nodejs:nodejs . .

# ─────────────────────────────────────────────────────────────────────────────
# SWITCH TO NON-ROOT USER
# ─────────────────────────────────────────────────────────────────────────────
# All subsequent RUN, CMD, ENTRYPOINT instructions run as 'nodejs'.
# This MUST come after COPY (copying as non-root can fail for system files).
USER nodejs

# ─────────────────────────────────────────────────────────────────────────────
# EXPOSE PORT
# ─────────────────────────────────────────────────────────────────────────────
# EXPOSE is documentation only — it does NOT open any network port.
# Actual port binding happens in:
#   - docker run -p 5000:5000 (local)
#   - docker-compose.yml ports: (compose)
#   - K8s Service spec.ports[].targetPort: 5000 (Kubernetes)
EXPOSE 5000

# ─────────────────────────────────────────────────────────────────────────────
# HEALTHCHECK
# ─────────────────────────────────────────────────────────────────────────────
# Docker's built-in health check. Used by docker-compose healthcheck.
# In Kubernetes, the K8s livenessProbe/readinessProbe takes precedence over this.
# But it's useful when running the container standalone (outside K8s).
#
# wget is available in alpine; curl is NOT (use wget or install curl separately)
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:${PORT}/health || exit 1

# ─────────────────────────────────────────────────────────────────────────────
# ENTRYPOINT & CMD
# ─────────────────────────────────────────────────────────────────────────────
# We use CMD (not ENTRYPOINT) for flexibility:
#   docker run <image>           → runs: node index.js (default)
#   docker run <image> sh        → opens a shell (for debugging)
#   docker run <image> node -e   → runs arbitrary node command
#
# JSON array form (["node", "index.js"]) is preferred over shell form ("node index.js"):
#   JSON array: process runs as PID 1 → receives SIGTERM directly → graceful shutdown
#   Shell form: shell is PID 1, node is a child → SIGTERM goes to shell, node may not get it
#
# PID 1 matters: Kubernetes sends SIGTERM to PID 1 for graceful termination.
# Our index.js handles SIGTERM (see graceful shutdown handler in index.js Day 3).
CMD ["node", "index.js"]
