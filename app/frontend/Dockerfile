# ─────────────────────────────────────────────────────────────────────────────
# app/frontend/Dockerfile — Production Multi-Stage Frontend Image
# ─────────────────────────────────────────────────────────────────────────────
#
# TWO-STAGE BUILD STRATEGY:
# ─────────────────────────────────────────────────────────────────────────────
#
# Stage 1 (builder): node:18-alpine
#   - Install all npm dependencies
#   - Run `npm run build` → compiles React + bundles with webpack
#   - Output: build/ directory (HTML, CSS, JS, assets)
#   - This stage is DISCARDED after build (doesn't go into final image)
#
# Stage 2 (runtime): nginx:alpine
#   - COPY the build/ output from Stage 1
#   - Nginx serves static files with zero Node.js runtime
#   - Result: ~22MB image (vs ~200MB if we kept Node.js)
#
# WHY THIS MATTERS FOR KUBERNETES:
# ─────────────────────────────────────────────────────────────────────────────
# Smaller images = faster pod startup in K8s.
# When K8s needs to scale out (new pod on a new node):
#   - 22MB image pulls in ~2 seconds (on EC2 with ECR in same region)
#   - 200MB image pulls in ~20+ seconds (8-10x slower scale-out)
#
# Nginx serves static files MUCH faster than Node.js:
#   - Nginx: ~100,000 req/s for static files (kernel-level sendfile)
#   - Node.js: ~10,000 req/s for static files (user-space)
#
# REACT_APP_BACKEND_URL BUILD ARG:
# ─────────────────────────────────────────────────────────────────────────────
# React env vars (REACT_APP_*) are baked into the bundle at BUILD TIME.
# We pass the backend URL as a Docker build argument (ARG → ENV).
#
# Local:  docker build --build-arg REACT_APP_BACKEND_URL=http://localhost:5000/api/tasks
# K8s CI: docker build --build-arg REACT_APP_BACKEND_URL=http://<ALB>/api/tasks
# ─────────────────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1: BUILD — Compile React App
# ═════════════════════════════════════════════════════════════════════════════
FROM node:18-alpine AS builder

# Accept the backend URL as a build argument.
# ARG is only available during the BUILD phase (not at container runtime).
# Default value for local development — override in CI/CD.
ARG REACT_APP_BACKEND_URL=http://localhost:5000/api/tasks

# Convert ARG → ENV so React (via webpack/Create React App) can read it.
# React's build process reads process.env.REACT_APP_* from Node's environment.
# This value gets compiled (baked) into the JavaScript bundle.
ENV REACT_APP_BACKEND_URL=${REACT_APP_BACKEND_URL}

# Build context = app/frontend/ (see docker-compose.yml build.context)
WORKDIR /app

# ─────────────────────────────────────────────────────────────────────────────
# LAYER CACHING OPTIMIZATION (same principle as backend Dockerfile)
# ─────────────────────────────────────────────────────────────────────────────
# Copy package files FIRST so npm ci is cached when only source code changes.
# npm ci takes 30-60 seconds. Source code changes happen 100x more often
# than package.json changes. This optimization saves minutes in CI/CD.
COPY package.json package-lock.json ./

# Install ALL dependencies (including devDeps like react-scripts for the build)
# We need devDependencies here because react-scripts IS a devDependency.
RUN npm ci

# Copy source code AFTER npm ci (so package cache layer is preserved)
COPY . .

# ─────────────────────────────────────────────────────────────────────────────
# BUILD THE REACT APPLICATION
# ─────────────────────────────────────────────────────────────────────────────
# npm run build executes react-scripts build (via Create React App).
# Internally, this runs:
#   1. Webpack: bundles all JS modules into build/static/js/main.<hash>.js
#   2. Babel: transpiles JSX → plain JS (browser compatible)
#   3. CSS: bundles and minifies CSS into build/static/css/main.<hash>.css
#   4. Assets: copies public/ directory to build/
#   5. index.html: injects <script> and <link> tags pointing to hashed bundles
#
# REACT_APP_BACKEND_URL is read HERE by webpack and embedded in the bundle.
# After this step, the bundle has NO knowledge of env vars — it's baked in.
#
# Output: /app/build/ directory containing:
#   build/
#   ├── index.html           (the HTML shell with injected script/link tags)
#   ├── static/
#   │   ├── js/main.abc.js   (all React code, bundled and minified)
#   │   ├── css/main.def.css (all CSS, bundled and minified)
#   │   └── media/           (images, fonts, etc.)
#   └── manifest.json, favicon.ico, etc.
RUN npm run build

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2: RUNTIME — Serve with Nginx
# ═════════════════════════════════════════════════════════════════════════════
# Only this stage goes into the final image — Stage 1 (node:18-alpine) is discarded.
FROM nginx:1.25-alpine AS runtime

# Metadata labels for ECR and container registries
LABEL maintainer="Harshads-git" \
      org.opencontainers.image.source="https://github.com/Harshads-git/three-tier-eks-portfolio" \
      org.opencontainers.image.description="Three-Tier Frontend — React SPA served by Nginx" \
      org.opencontainers.image.version="1.0.0"

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY: Run Nginx as non-root
# ─────────────────────────────────────────────────────────────────────────────
# nginx:alpine runs as root by default (nginx master process needs root to bind port 80).
# We can't fully avoid root for port binding, but we can run worker processes as a
# dedicated user (configured in nginx.conf with `user nginx;`).
#
# Alternative: Use Nginx Unprivileged image (port 8080 instead of 80):
#   FROM nginxinc/nginx-unprivileged:1.25-alpine
#   This runs entirely as non-root but requires Service port change.
# We use standard nginx:alpine for simplicity, documented for awareness.

# ─────────────────────────────────────────────────────────────────────────────
# COPY NGINX CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
# Replace the default nginx.conf with our custom config.
# Our nginx.conf handles:
#   1. SPA routing: try_files → /index.html (for React Router)
#   2. Gzip compression: reduces bundle size by ~70%
#   3. Cache headers: long-term cache for hashed static assets
#   4. Security headers: X-Frame-Options, X-Content-Type-Options, etc.
#   5. Health check: GET /nginx-health → 200 OK
COPY nginx.conf /etc/nginx/nginx.conf

# ─────────────────────────────────────────────────────────────────────────────
# COPY REACT BUILD OUTPUT FROM STAGE 1
# ─────────────────────────────────────────────────────────────────────────────
# COPY --from=builder: Pulls from Stage 1's filesystem, not host.
# Only the compiled static files land in the final image.
# No Node.js, no npm, no react-scripts, no node_modules in the final image.
COPY --from=builder /app/build /usr/share/nginx/html

# ─────────────────────────────────────────────────────────────────────────────
# PERMISSIONS
# ─────────────────────────────────────────────────────────────────────────────
# Ensure Nginx can read the static files.
# nginx user (created by the official image) reads from /usr/share/nginx/html.
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html

# ─────────────────────────────────────────────────────────────────────────────
# PORT
# ─────────────────────────────────────────────────────────────────────────────
# Nginx listens on port 80 (configured in nginx.conf).
# K8s Service maps: host/ALB:80 → pod:80 (docker-compose: 3000:80)
EXPOSE 80

# ─────────────────────────────────────────────────────────────────────────────
# HEALTHCHECK (for docker-compose and standalone docker run)
# ─────────────────────────────────────────────────────────────────────────────
# K8s uses its own livenessProbe/readinessProbe (Day 19).
# This healthcheck is for docker-compose health gating.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:80/nginx-health || exit 1

# ─────────────────────────────────────────────────────────────────────────────
# STARTUP COMMAND
# ─────────────────────────────────────────────────────────────────────────────
# nginx -g "daemon off;":
#   -g "daemon off;" → Run Nginx in the FOREGROUND.
#   Without this, Nginx forks to background and Docker sees PID 1 exit → container stops.
#   Containers require PID 1 to stay running. "daemon off" keeps Nginx as PID 1.
#
# JSON array form: Nginx receives SIGTERM directly as PID 1 → graceful shutdown.
# Nginx handles SIGTERM by finishing in-flight requests then stopping workers.
CMD ["nginx", "-g", "daemon off;"]
