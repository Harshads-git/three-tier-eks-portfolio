# CI/CD Pipeline Architecture

## Overview — Three Workflows

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ci.yml — Runs on every PR and push to main                                 │
│                                                                             │
│  Pull Request / Push                                                        │
│       │                                                                     │
│       ├── test-backend      (npm test, npm lint)        ┐                  │
│       ├── test-frontend     (npm test --watchAll=false)  ├── parallel       │
│       │                                                                     │
│       └── build-and-scan   (after tests pass)           ┐                  │
│           ├── Build backend image (Buildx)               ├── matrix:        │
│           ├── Build frontend image                       │   [backend,      │
│           ├── Trivy scan → SARIF → GitHub Security tab   │    frontend]     │
│           └── validate-manifests (kubeconform)           ┘                  │
│                                                                             │
│       → ci-success gate (all must pass)                                     │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  cd.yml — Runs ONLY when ci.yml succeeds on main                            │
│                                                                             │
│  CI passes → CD triggers                                                   │
│       │                                                                     │
│       ├── set-vars (image_tag = sha-a1b2c3d)                                │
│       │                                                                     │
│       ├── push-backend  ─┐                                                  │
│       │   OIDC → ECR      ├── parallel (both push simultaneously)           │
│       └── push-frontend ─┘                                                  │
│                                                                             │
│       └── deploy (after both ECR pushes complete)                           │
│           OIDC → kubectl set image → rollout status → verify health        │
│                                                                             │
│       └── notify-failure (only if any job fails → create GitHub Issue)      │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  terraform.yml — Runs when terraform/** changes                              │
│                                                                             │
│  Pull Request → terraform plan → post as PR comment (for review)           │
│  Push to main → terraform apply (auto, since plan was reviewed in PR)       │
│  Manual        → choose: plan | apply | destroy                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## GitHub Secrets Required

Before the workflows run, configure these secrets in:
`GitHub → Settings → Secrets and variables → Actions`

| Secret Name | Value | Used By |
|---|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account number | `cd.yml`, `terraform.yml` |
| `ALB_DNS` | ALB DNS name (from `terraform output`) | `cd.yml` (frontend build-arg) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform state | `terraform.yml` |
| `TF_LOCK_TABLE` | DynamoDB table name for state lock | `terraform.yml` |
| `TF_CLUSTER_NAME` | EKS cluster name (optional, has default) | `terraform.yml` |

> **Note**: No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` needed. OIDC handles authentication automatically.

---

## Image Tagging Strategy

```
Every merge to main produces:
  sha-a1b2c3d    ← git short SHA (7 chars, immutable, traceable)
  latest         ← convenience tag (always newest)

Kubernetes deployment image:
  123456789012.dkr.ecr.us-east-1.amazonaws.com/three-tier-eks-cluster-backend:sha-a1b2c3d

Rollback command (if deployment breaks):
  kubectl rollout undo deployment/backend -n three-tier
  # OR: roll back to a specific image:
  kubectl set image deployment/backend \
    backend=123456789012.dkr.ecr.us-east-1.amazonaws.com/three-tier-eks-cluster-backend:sha-previous

Finding the previous SHA:
  git log --oneline -5   ← see recent commits
  aws ecr list-images --repository-name three-tier-eks-cluster-backend
```

---

## Trivy Security Scanning

```
Every CI run:
  Build image → Trivy scans for:
    OS packages (Alpine apk)
    npm dependencies (in node_modules or package.json)
    Dockerfile misconfigurations

  Results:
    CRITICAL: Pipeline FAILS (exit-code: 1) → cannot merge
    HIGH: Reported but pipeline continues
    Uploaded to: GitHub Security → Code Scanning → Trivy (SARIF format)

How to view scan results:
  GitHub → Security → Code Scanning
  Or: CLI: trivy image three-tier-backend:sha-abc1234

How to fix a CRITICAL CVE:
  1. Identify: trivy image --severity CRITICAL <image>
  2. Update base image: FROM node:18-alpine → FROM node:20-alpine
  3. Or: Update the vulnerable npm package: npm update <package>
  4. Rebuild and scan again
```

---

## Deployment Flow — Zero Downtime

```
kubectl set image deployment/backend backend=<new-image>
                    │
                    ▼
          Rolling Update starts (maxSurge:1, maxUnavailable:0)

Current state: [backend-v1-pod1] [backend-v1-pod2]

Step 1: Create new pod → [v1-pod1] [v1-pod2] [v2-pod3]
Step 2: v2-pod3 readinessProbe passes → added to Service endpoints
Step 3: v1-pod1 SIGTERM → graceful 30s shutdown → removed
        [v1-pod2] [v2-pod3]
Step 4: Create v2-pod4 → [v1-pod2] [v2-pod3] [v2-pod4]
Step 5: v2-pod4 ready → v1-pod2 terminated
Final:  [v2-pod3] [v2-pod4] ← new version, zero downtime!

kubectl rollout status deployment/backend -n three-tier
→ Waits until the above completes (or fails after 300s timeout)
→ If rollout fails: GitHub Actions job fails → deployment marked failed
→ Pods in bad state: kubectl rollout undo deployment/backend -n three-tier
```

---

## Terraform Plan-on-PR Pattern

```
Developer opens PR with terraform/eks.tf changes
    │
    ▼
terraform.yml runs terraform plan
    │
    ├── Plan output posted as PR comment automatically:
    │   "Plan: 3 to add, 1 to change, 0 to destroy"
    │   Shows exact resources being created/modified/destroyed
    │
    ▼
Reviewer reads the plan → approves or requests changes
    │
    ▼
PR merged to main
    │
    ▼
terraform.yml runs terraform apply -auto-approve
    │
    ▼
Infrastructure updated!
```

> **Why this matters**: Without plan-on-PR, infrastructure changes are "blind" — reviewers see HCL code but don't know the actual AWS impact. With plan output in the PR, the reviewer knows exactly what will change before approving.

---

## Concurrency Control

```yaml
concurrency:
  group: cd-production
  cancel-in-progress: false  # ← NEVER cancel a running deployment
```

- **CI**: `cancel-in-progress: true` — if new commit pushed, cancel old CI (save minutes)
- **CD**: `cancel-in-progress: false` — never interrupt a deployment in progress (could leave cluster in broken state with half-rolled-out pods)
- **Terraform**: `cancel-in-progress: false` — never interrupt an apply (could corrupt state)

---

## GitHub Environments — Manual Approval Gate

For production deployments, add a required reviewer:

```
GitHub → Settings → Environments → production
  → Required reviewers: [your-username]
  → Wait timer: 0 minutes
```

With this configured, the `deploy` job waits for a human to approve before deploying to EKS. The approval UI shows the deployment context, commit, and who triggered it.
