# Repository Structure & Folder Conventions

This document explains the purpose of every folder in this repository and the conventions used for organizing files.

---

## Top-Level Structure

```
three-tier-eks-portfolio/
│
├── app/                    # Application source code (all 3 tiers)
│   ├── frontend/           # React SPA (Presentation Tier)
│   └── backend/            # Node.js/Express API (Logic Tier)
│
├── k8s/                    # Kubernetes manifests (raw YAML)
│   ├── frontend/           # Frontend Deployment, Service, HPA
│   ├── backend/            # Backend Deployment, Service, HPA
│   ├── mongo/              # MongoDB StatefulSet, Secret, Service
│   ├── monitoring/         # ServiceMonitor, Grafana Dashboard
│   └── helm/               # Helm chart for the full application
│       └── three-tier-app/ # Helm chart directory
│
├── terraform/              # AWS Infrastructure as Code
│   ├── provider.tf         # AWS provider & version constraints
│   ├── backend.tf          # Remote state (S3 + DynamoDB lock)
│   ├── variables.tf        # Input variables with validation
│   ├── outputs.tf          # Output values for cross-tool use
│   ├── vpc.tf              # VPC, subnets, NAT Gateway, IGW
│   ├── eks.tf              # EKS cluster and node groups
│   ├── ecr.tf              # ECR repositories for images
│   ├── iam.tf              # IAM roles, OIDC provider (IRSA)
│   ├── autoscaler-iam.tf   # Cluster Autoscaler IAM role (IRSA)
│   ├── autoscaler-manifest.tf  # Cluster Autoscaler K8s deployment
│   ├── ebs_csi_driver.tf   # EBS CSI Driver add-on
│   ├── helm-provider.tf    # Helm Terraform provider config
│   ├── helm-load-balancer-controller.tf  # AWS LB Controller
│   ├── monitoring.tf       # Prometheus + Grafana Helm release
│   └── values.yaml         # kube-prometheus-stack custom values
│
├── docs/                   # All documentation
│   ├── architecture.md     # System design and diagrams
│   ├── repo-structure.md   # This file
│   ├── api-contract.md     # REST API endpoint documentation
│   ├── local-setup.md      # How to run locally
│   ├── docker-backend.md   # Backend Dockerfile explanation
│   ├── docker-frontend.md  # Frontend Dockerfile explanation
│   ├── ecr-push-guide.md   # ECR image push workflow
│   ├── vpc-architecture.md # VPC design decisions
│   ├── eks-architecture.md # EKS cluster design
│   ├── iam-irsa.md         # IRSA pattern documentation
│   ├── cluster-addons.md   # Helm-deployed add-ons
│   ├── autoscaling.md      # HPA and Cluster Autoscaler
│   ├── monitoring.md       # Prometheus and Grafana setup
│   ├── helm-chart.md       # Helm chart documentation
│   ├── ci-cd.md            # CI/CD pipeline documentation
│   ├── observability.md    # SLI/SLO/alerting strategy
│   ├── troubleshooting.md  # Common issues and fixes
│   ├── cost-analysis.md    # AWS cost breakdown
│   ├── cost-optimization.md # Cost reduction strategies
│   ├── runbook.md          # End-to-end deployment runbook
│   ├── roadmap.md          # 30-day project roadmap
│   └── adr/                # Architecture Decision Records
│       ├── ADR-001-eks-vs-ecs.md
│       ├── ADR-002-helm-vs-kustomize.md
│       └── ADR-003-irsa-vs-instance-profiles.md
│
├── scripts/                # Automation helper scripts
│   └── build-and-push.sh   # Docker build + ECR push script
│
├── policy/                 # OPA/Conftest Rego policies
│   └── k8s-policies.rego   # K8s manifest policies (no :latest, etc.)
│
├── .github/
│   ├── workflows/          # GitHub Actions CI/CD pipelines
│   │   ├── ci-backend.yml  # Backend CI: lint, test, build, scan, push
│   │   ├── cd.yml          # CD: deploy to EKS via Helm
│   │   └── terraform-plan.yml  # PR: terraform fmt/validate/plan
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── CODEOWNERS          # Code ownership rules
│
├── .gitignore              # Files excluded from git tracking
├── .trivyignore            # Trivy vulnerability exceptions
├── docker-compose.yml      # Local development environment
├── Makefile                # Common developer commands
├── LICENSE                 # MIT License
└── README.md               # Project overview and quick start
```

---

## File Naming Conventions

| Convention | Rule | Example |
|---|---|---|
| **Terraform files** | `noun-or-component.tf` | `vpc.tf`, `eks.tf`, `iam.tf` |
| **K8s manifests** | `resource-type.yaml` | `deployment.yaml`, `service.yaml` |
| **Docs** | `topic-area.md` (kebab-case) | `vpc-architecture.md` |
| **Scripts** | `verb-noun.sh` | `build-and-push.sh` |
| **GitHub workflows** | `trigger-target.yml` | `ci-backend.yml`, `cd.yml` |
| **Helm values** | `values-<env>.yaml` | `values-dev.yaml`, `values-prod.yaml` |

---

## Branch Strategy

```
main                    ← Production-ready code only
├── develop             ← Integration branch (all features merge here)
│   ├── feature/day-6-dockerization     ← Feature branches
│   ├── feature/day-11-terraform-vpc
│   └── fix/backend-health-probe
└── release/v1.0.0      ← Release branches (optional)
```

### Branch Naming Rules

| Type | Pattern | Example |
|---|---|---|
| Feature | `feature/<day>-<description>` | `feature/day-6-dockerization` |
| Bug Fix | `fix/<description>` | `fix/backend-env-var-missing` |
| Documentation | `docs/<description>` | `docs/update-eks-architecture` |
| Release | `release/v<semver>` | `release/v1.0.0` |

### Commit Message Convention (Conventional Commits)

```
<type>(<scope>): <short description>

Types:
  feat     - A new feature
  fix      - A bug fix
  docs     - Documentation only changes
  chore    - Build process or auxiliary tool changes
  refactor - Code change that neither fixes a bug nor adds a feature
  test     - Adding missing tests
  ci       - Changes to CI configuration files and scripts
  release  - Version bumps and release commits

Examples:
  feat(backend): add health check endpoint for K8s probes
  docs(architecture): add VPC topology diagram
  chore(terraform): run fmt and validate
  ci(github-actions): add Trivy scan step to backend workflow
```

---

## Environment Strategy

| Environment | Branch | AWS Account | Purpose |
|---|---|---|---|
| **Local** | any | N/A | Docker Compose, development |
| **CI** | any PR | N/A | Automated testing |
| **Staging** | `develop` | Dev account | Integration testing |
| **Production** | `main` | Prod account | Live traffic |
