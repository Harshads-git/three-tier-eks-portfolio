# Contributing to Three-Tier EKS Portfolio

Thank you for considering contributing to this project! This guide covers the development workflow, coding standards, and PR process.

---

## Development Setup

### Prerequisites

```bash
# Install required tools
brew install awscli terraform kubectl helm k6
# or on Ubuntu/Debian:
# apt-get install awscli kubectl helm
# snap install terraform --classic

# Install Node.js 18+
nvm install 18
nvm use 18

# Verify all tools
aws --version && terraform --version && kubectl version --client && helm version
```

### Local Development (without cluster)

```bash
# Clone the repo
git clone https://github.com/Harshads-git/three-tier-eks-portfolio.git
cd three-tier-eks-portfolio

# Run app locally with Docker Compose
# (Docker Compose file runs: frontend + backend + MongoDB)
docker compose up -d

# Test backend API
curl http://localhost:5000/api/health
curl http://localhost:5000/api/tasks

# Access frontend
open http://localhost:3000
```

---

## Project Standards

### Git Commit Convention

All commits MUST follow this format:

```
<type>: <description in lowercase>

<body explaining the WHY and key decisions>
```

**Types:**
- `feat:` — New feature or resource
- `fix:` — Bug fix
- `docs:` — Documentation only
- `refactor:` — Code change that neither fixes a bug nor adds a feature
- `test:` — Adding or updating tests
- `chore:` — Maintenance (dependency updates, CI config)

**Example commit:**
```
feat: add PodDisruptionBudget for MongoDB StatefulSet

k8s/pdb/poddisruptionbudgets.yaml:
  minAvailable: 1 with replicas=1 -> 0 disruptions allowed
  kubectl drain will block until MongoDB rescheduled
  Intentional: data loss risk outweighs drain convenience
  Production note: 3-node replica set -> change to minAvailable: 2
```

### Code Standards

**Kubernetes manifests:**
- All resources MUST have `app.kubernetes.io/name`, `app.kubernetes.io/component`, `app.kubernetes.io/part-of` labels
- All resources MUST have `annotations.description` explaining the purpose
- Resource requests AND limits MUST be set on every container
- No `latest` tags in manifests (use specific versions or `sha-` prefixed ECR tags)

**Terraform:**
- All resources MUST have `Name` tag and `Project`, `Environment`, `ManagedBy` tags
- All variables MUST have `description` and `type`
- Sensitive variables MUST have `sensitive = true`
- `terraform fmt` must pass before commit

**Shell scripts:**
- Start with `set -euo pipefail`
- Use color-coded output (GREEN=ok, YELLOW=warn, RED=error)
- Exit 0 on success, non-zero on failure (enables CI integration)

---

## Pull Request Process

1. **Fork** the repository
2. **Branch naming**: `feat/short-description`, `fix/issue-description`, `docs/topic`
3. **Make changes** with descriptive commits
4. **Test locally**: `kubectl apply --dry-run=client -f k8s/` for manifest changes
5. **Validate**: `kubeconform k8s/**/*.yaml` for schema validation
6. **Open PR**: Fill in the PR template (added below)
7. **CI must pass**: All 4 CI jobs must succeed before review

### PR Checklist

```markdown
## Changes
- [ ] Describe what changed and why

## Type of Change
- [ ] feat: New feature/resource
- [ ] fix: Bug fix
- [ ] docs: Documentation
- [ ] refactor: Code restructure

## Testing
- [ ] `kubectl apply --dry-run=client` passes
- [ ] `terraform validate` passes (if Terraform changes)
- [ ] CI workflow passes

## Documentation
- [ ] Relevant docs updated (if applicable)
- [ ] Commit messages follow convention
```

---

## Adding New Kubernetes Resources

When adding a new K8s resource, always include:

1. **The manifest** with full annotations
2. **A NetworkPolicy update** if the resource makes network calls
3. **A ResourceQuota check** to verify it fits within namespace limits
4. **Documentation** in the relevant `docs/` file

```bash
# Validate your manifest
kubectl apply --dry-run=client -f k8s/your-resource.yaml

# Validate schema
kubeconform -strict k8s/your-resource.yaml

# Check if it fits within ResourceQuota
kubectl describe resourcequota three-tier-quota -n three-tier
```

---

## Adding New Terraform Resources

```bash
# Validate HCL syntax
cd terraform && terraform validate

# Check formatting
terraform fmt -check -diff

# Preview changes (never apply without reviewing plan first)
terraform plan

# Apply only after team review
terraform apply
```

---

## Questions?

Open a [GitHub Discussion](https://github.com/Harshads-git/three-tier-eks-portfolio/discussions) for:
- Architecture questions
- Help setting up the project
- Suggestions for improvement

Open a [GitHub Issue](https://github.com/Harshads-git/three-tier-eks-portfolio/issues) for:
- Bug reports
- Feature requests
- Documentation improvements
