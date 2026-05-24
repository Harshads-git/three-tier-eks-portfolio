# Frontend Dependency Notes & Security Audit

## Overview

This document tracks the npm packages used in `app/frontend/`, their versions, security status, and upgrade considerations relevant to this DevOps portfolio project.

---

## Dependency Audit

### Production Dependencies

| Package | Pinned Version | Latest (May 2026) | Security Notes |
|---|---|---|---|
| `react` | `^17.0.2` | 18.x | React 17 is stable but EOL. Upgrade path: `react@18` with `createRoot()` |
| `react-dom` | `^17.0.2` | 18.x | Tied to `react` version — must upgrade together |
| `axios` | `^0.21.1` | 1.x | **KNOWN CVEs in 0.21.x** — Upgrade to `axios@1.x` (breaking changes in config API) |
| `@material-ui/core` | `^4.11.4` | @mui/material v5 | v4 is in maintenance mode. `emotion` replaces `JSS` in v5 |
| `react-scripts` | `4.0.3` | 5.x | CRA is deprecated upstream — Consider Vite for new projects |
| `web-vitals` | `^1.1.2` | 3.x | Measurement API is backward-compatible — safe to upgrade |

### Dev / Test Dependencies

| Package | Version | Purpose |
|---|---|---|
| `@testing-library/react` | `^11.2.7` | Component testing |
| `@testing-library/jest-dom` | `^5.14.1` | Custom Jest matchers |
| `@testing-library/user-event` | `^12.8.3` | User interaction simulation |

---

## Security Considerations

### axios ^0.21.1 — CVE Notes

```
axios 0.21.x has known SSRF (Server-Side Request Forgery) vulnerabilities.
In this frontend context, axios runs in the BROWSER — it's the client, not a server.
Client-side SSRF is not applicable here.

However, the broader concern is:
- axios 0.x uses a different config API than axios 1.x
- Upgrading to axios@1.x requires testing all four service functions in taskServices.js

Upgrade plan (Day 9+): Pin to axios@1.6.x in package.json
```

### react-scripts 4.x — Security Notes

```
Create React App (react-scripts) has transitive dependency vulnerabilities
in its toolchain (webpack 4, babel, etc.). These are BUILD-TIME vulnerabilities,
not runtime ones — they do NOT affect the deployed Docker image.

The compiled output (build/) has no Node.js runtime dependencies.
Nginx serves only static files — no Node.js attack surface at runtime.

Upgrade plan: This is a known issue across all CRA projects.
For production, migrating to Vite would resolve this entirely.
```

### @material-ui/core ^4.11.4

```
MUI v4 uses JSS for styling, which has no active security issues.
It is in maintenance-only mode (no new features, only critical security fixes).

Risk: Low for a portfolio project
Upgrade: @mui/material v5 (emotion-based) — requires JSX transform changes
```

---

## How This Affects Docker & Kubernetes

### What Goes Into the Docker Image?

```bash
# Stage 1: Builder (node:18-alpine)
npm ci             # Installs ALL dependencies including devDependencies
npm run build      # webpack compiles to build/

# Stage 2: Runtime (nginx:alpine)
COPY build/ /usr/share/nginx/html/
# ← Only the compiled static files land here
# ← NO node_modules, NO npm, NO react-scripts in the final image
```

**Key insight**: The vulnerabilities in `react-scripts`, `webpack`, and development tooling packages **do NOT end up in the production Docker image**. They only run during the build phase.

The final Nginx image only contains:
- `nginx` binary
- Compiled HTML/CSS/JS files (from `build/`)

### npm ci vs npm install

We use `npm ci` (not `npm install`) in the Dockerfile because:
- `npm ci` uses `package-lock.json` for exact, reproducible builds
- `npm install` might update minor/patch versions (non-deterministic)
- Reproducibility is critical for CI/CD — every build must produce the same output

---

## Dependency Update Strategy

For this 30-day project, we use a **conservative update strategy**:

| Priority | Package | Action |
|---|---|---|
| ⚠️ Medium | `axios` | Upgrade to `^1.6.x` when refactoring taskServices.js (Day 9) |
| 🔵 Low | `react` | Keep 17.x for project duration; note upgrade path in ADR |
| 🔵 Low | `@material-ui/core` | Keep v4; note MUI v5 migration in production improvement doc |
| 🔵 Low | `react-scripts` | Keep 4.x; note Vite migration as improvement |
| ✅ None | `@testing-library/*` | No action needed |

---

## Running Security Audit Yourself

```bash
# Navigate to frontend directory
cd app/frontend

# Install dependencies first
npm ci

# Run audit (shows vulnerabilities and their severity)
npm audit

# Auto-fix minor/patch vulnerabilities (use with caution)
npm audit fix

# Show full audit report as JSON (pipe to file for records)
npm audit --json > npm-audit-report.json

# Check for outdated packages
npm outdated
```

---

## Production Readiness Notes

For a real production deployment, the following would be in the CI/CD pipeline:

```yaml
# In .github/workflows/ci-frontend.yml (Day 24):
- name: Run npm audit
  run: |
    cd app/frontend
    npm audit --audit-level=high
    # Fail CI if HIGH or CRITICAL vulnerabilities found
```

This ensures no image with known high-severity vulnerabilities gets deployed to EKS.
