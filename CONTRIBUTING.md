# Contributing to Three-Tier EKS Portfolio

Thank you for your interest in contributing! This document outlines the workflow and standards for contributing to this project.

---

## 🌿 Branching Strategy

We follow a **GitFlow-inspired** branching model:

```
main          ← Always production-ready
develop       ← Integration branch (merge features here)
feature/*     ← New features and daily development work
fix/*         ← Bug fixes
docs/*        ← Documentation updates
```

### Creating a Branch

```bash
# Always branch from develop (not main)
git checkout develop
git pull origin develop
git checkout -b feature/day-X-description

# Example:
git checkout -b feature/day-6-backend-dockerfile
```

---

## 💬 Commit Message Convention

This project follows the **Conventional Commits** specification.

```
<type>(<scope>): <description>

Body (optional):
Explain WHY the change was made, not WHAT (the code shows that).

Footer (optional):
Refs: #issue-number
```

### Types

| Type | When to Use |
|---|---|
| `feat` | New feature or file |
| `fix` | Bug fix |
| `docs` | Documentation changes only |
| `chore` | Non-production code changes (gitignore, config) |
| `refactor` | Code restructuring without behavior change |
| `test` | Adding or modifying tests |
| `ci` | CI/CD pipeline changes |
| `release` | Version tag commits |

### Good Commit Message Examples

```bash
# Good ✅
feat(backend): add health check endpoint for Kubernetes probes
docs(vpc): add network topology diagram for multi-AZ design
chore(terraform): run fmt and validate all tf files
fix(frontend): correct API base URL in nginx config

# Bad ❌
update stuff
fix bug
changes
wip
```

---

## 🔄 Pull Request Process

1. **Create your branch** from `develop`
2. **Make your changes** with atomic, well-described commits
3. **Push your branch**: `git push origin feature/your-branch`
4. **Open a PR** against `develop` (not `main`)
5. **Fill the PR template** — describe what changed and why
6. **Ensure CI passes** — all GitHub Actions checks must be green
7. **Request a review** if applicable

---

## ✅ Definition of Done (For Each Day's Work)

- [ ] All 4 commits made with descriptive messages
- [ ] No secrets or credentials in any committed file
- [ ] New files have inline comments explaining non-obvious decisions
- [ ] Relevant documentation updated
- [ ] `terraform fmt` run if Terraform files changed
- [ ] All existing tests still pass

---

## 🚫 What NOT to Commit

- `.env` files with real values
- `*.tfstate` or `.terraform/` directories
- AWS credentials or access keys
- Kubeconfig files
- `node_modules/`
- Any file containing passwords, tokens, or secrets

---

## 📁 File Organization

Please follow the conventions defined in [docs/repo-structure.md](./docs/repo-structure.md).

---

## 🙏 Code of Conduct

Be respectful, constructive, and professional in all interactions.
