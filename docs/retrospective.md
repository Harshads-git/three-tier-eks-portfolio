# Project Retrospective — 20-Day Three-Tier EKS Build

## What Was Built

A complete production-grade DevOps portfolio project built over 20 days — one hour per day, four commits per day, 80 commits total.

---

## The 20-Day Journey

| Day | What Was Built | Key Skill Demonstrated |
|---|---|---|
| **1** | Project scaffold, backend Node.js API, MongoDB connection | Application architecture |
| **2** | React frontend, SPA routing, API integration | Full-stack development |
| **3** | Docker multi-stage builds (backend + frontend) | Container best practices |
| **4** | `.dockerignore`, Docker Compose, ECR repositories | Image optimization, registry setup |
| **5** | K8s manifests: Namespace, Deployment, Service, ConfigMap | Core K8s resources |
| **6** | StatefulSet (MongoDB), PVC, HPA, resource limits | Stateful workloads, autoscaling |
| **7** | SecurityContext (non-root, read-only FS), RBAC | Container and cluster security |
| **8** | ALB Ingress, path-based routing, IAM for ALB Controller | AWS-native load balancing |
| **9** | Terraform VPC, S3/DynamoDB backend, provider config | Infrastructure as Code foundations |
| **10** | Terraform EKS cluster, ECR, EBS CSI driver, CA add-on | Managed Kubernetes infrastructure |
| **11** | IRSA (GitHub OIDC, ALB Controller, CA), Helm releases | Identity federation, GitOps tooling |
| **12** | GitHub Actions CI (test + Trivy + kubeconform), CD (OIDC + rolling deploy), Terraform workflow | Production CI/CD pipelines |
| **13** | NetworkPolicies (deny-all + explicit allows), PodDisruptionBudgets, ResourceQuota + LimitRange | Zero-trust networking, resilience |
| **14** | kube-prometheus-stack Helm values, ServiceMonitors, PrometheusRule with 8 alerts | Full observability stack |
| **15** | k6 smoke/load/stress/HPA validation tests, automated GitHub Actions load test workflow | Performance testing, chaos validation |
| **16** | Operations runbook, cost analysis, cluster health check script, disaster recovery plan | SRE operations |
| **17** | Architecture document, 5 Mermaid diagrams, interview prep guide | Documentation and communication |
| **18** | Master README, CONTRIBUTING.md, LICENSE, GitHub issue templates | Project presentation |
| **19** | Hardened .gitignore, docker-compose.yml, Makefile (40+ targets), pre-commit hook | Developer experience |
| **20** | k8s-apply.sh script, validation checklist, retrospective | Project completion |

---

## Key Engineering Decisions (and Why They Matter)

### 1. OIDC over Access Keys
**Decision**: GitHub Actions uses OIDC federation, not stored `AWS_ACCESS_KEY_ID`.
**Why it matters in an interview**: Demonstrates understanding of cloud identity, short-lived credentials, and principle of least privilege. Access keys are the #1 cause of AWS account breaches.

### 2. Immutable ECR Tags
**Decision**: `repository_image_tag_mutability = "IMMUTABLE"`, image tags use git SHA (`sha-abc1234`).
**Why it matters**: Rollbacks are only meaningful if the tag you roll back to is guaranteed to contain the code you expect. Mutable `v1.0.0` tags can silently change.

### 3. NetworkPolicy Deny-All First
**Decision**: Apply `default-deny-all` before any allow policies.
**Why it matters**: "Default allow" means a misconfigured service can accidentally expose MongoDB to the internet. "Default deny" means a misconfigured allow is a noisy but non-catastrophic failure.

### 4. Plan-on-PR, Apply-on-Merge (Terraform)
**Decision**: Terraform plan output posted as PR comment; apply only on merge.
**Why it matters**: Reviewers see "Plan: 3 to add, 1 to change, 0 to destroy" — not raw HCL that requires Terraform expertise to interpret. Infrastructure changes get the same review rigor as application code.

### 5. `for: 5m` on Alert Rules
**Decision**: Every alert has a `for:` duration before firing.
**Why it matters**: Without it, a single pod restart fires a CRITICAL alert. With `for: 5m`, only sustained issues create noise. Ops teams that ignore alerts are teams with too many false positives.

### 6. PDB minAvailable, Not maxUnavailable
**Decision**: `minAvailable: 1` on all workloads.
**Why it matters**: With small replica counts (2), `minAvailable: 1` is more intuitive. "Keep at least 1 alive" is clearer than "let at most 1 go down" when reasoning about safety during node drains.

---

## What Would Be Different in Production

### Application-Level
```
Portfolio:
  Single-node MongoDB (StatefulSet replicas: 1)
  No MongoDB authentication complexity
  Hardcoded MONGO_URI in ConfigMap

Production:
  MongoDB Atlas (managed, 3-node replica set, automated backups)
  OR MongoDB StatefulSet with 3 replicas + arbiter + PDB minAvailable: 2
  Secrets managed via AWS Secrets Manager → ExternalSecrets Operator
  MongoDB connection pooling configured per backend instance count
```

### Infrastructure
```
Portfolio:
  Single NAT Gateway (single point of failure for egress)
  t3.medium nodes (cost-optimized)
  Manual Terraform applies

Production:
  One NAT Gateway per AZ (HA egress, +$33/month)
  Mixed on-demand + Spot node groups (karpenter for smarter scheduling)
  Atlantis or Spacelift for automated Terraform GitOps
  Multiple environments: dev/staging/prod with separate AWS accounts
```

### Security
```
Portfolio:
  NetworkPolicies (VPC CNI enforcement)
  IRSA for pod identity

Production:
  AWS GuardDuty (threat detection)
  Amazon Inspector (CVE scanning of EC2 nodes and container images)
  Falco (runtime security monitoring — detect anomalous pod behavior)
  OPA/Gatekeeper (policy enforcement beyond NetworkPolicy)
  Pod Security Admission (enforce restricted PSS)
  Certificate Manager (automatic TLS for all ingress)
```

### Observability
```
Portfolio:
  Prometheus + Grafana (single instance, 30d retention)
  Manual AlertManager configuration
  No distributed tracing

Production:
  Thanos (long-term Prometheus storage, global view, HA)
  Grafana OnCall or PagerDuty (on-call rotation, escalation policies)
  OpenTelemetry + AWS X-Ray (distributed tracing)
  CloudWatch Container Insights (AWS-native logs integration)
  SLO/SLA tracking (99.9% uptime = 8.77 hours downtime/year budget)
```

### CI/CD
```
Portfolio:
  Single branch (main), manual environment promotion

Production:
  GitFlow or trunk-based with environment branches
  Canary deployments (Argo Rollouts: 5% → 25% → 100% traffic)
  Progressive delivery with automatic rollback on error rate spike
  SBOM (Software Bill of Materials) generation per image
  Policy gates: "no Critical CVE" + "min test coverage 80%"
```

---

## Concepts Mastered

After 20 days of building this project, you now have **hands-on understanding** of:

### Kubernetes Internals
- Pod lifecycle, readinessProbe vs livenessProbe, terminationGracePeriodSeconds
- StatefulSet vs Deployment (identity, ordered deployment, PVC retention)
- HPA: metrics pipeline (kubelet → Metrics Server → HPA controller → ReplicaSet)
- ResourceQuota + LimitRange interaction (admission controller injection)
- NetworkPolicy enforcement model (CNI plugin, not K8s API server)
- PodDisruptionBudget: voluntary vs involuntary disruptions

### AWS Services
- EKS: managed control plane, node groups, OIDC provider, add-ons
- VPC: subnets, route tables, NAT Gateway, Internet Gateway, security groups
- IAM: OIDC federation, AssumeRoleWithWebIdentity, trust policies, IRSA
- ECR: image push/pull, lifecycle policies, immutable tags
- EBS: dynamic provisioning via CSI driver, gp2/gp3 StorageClass, volume expansion
- ALB: target groups (instance vs IP mode), listener rules, health checks

### DevOps Practices
- GitOps: infrastructure and application config in git, automated reconciliation
- Shift-left security: scan images in CI, validate manifests, pre-commit hooks
- Progressive delivery: rolling updates, rollback procedures, zero-downtime deployments
- Observability: metrics → alerting → runbook → incident response → post-mortem cycle
- Cost optimization: right-sizing, Spot instances, lifecycle policies, budget alerts

---

## Numbers to Remember

| Metric | Value |
|---|---|
| Total commits | ~80 (4/day × 20 days) |
| Total files | 102+ production files |
| Kubernetes manifests | 20 YAML files |
| Documentation | 11 Markdown docs |
| GitHub Actions workflows | 4 pipelines |
| Terraform resources | ~40 AWS resources |
| k6 test scripts | 4 (smoke/load/stress/HPA) |
| Alert rules | 8 custom PrometheusRules |
| AWS monthly cost | ~$181 (always-on) / ~$18 (destroy-when-idle) |
| EKS control plane cost | $73/month (always-on, unavoidable) |
| HPA scale-up latency | 30-90 seconds |
| HPA scale-down window | 5 minutes (thrashing prevention) |
| IRSA token TTL | 1 hour (auto-rotated) |
| Prometheus retention | 30 days / 10 GiB |
| Rolling update strategy | maxSurge=1, maxUnavailable=0 |

---

## Final Thoughts

This project was built with one constraint: **production quality or nothing**.

Every file has comments explaining the **WHY**, not just the **WHAT**. Every design decision has a documented trade-off. Every alert has a corresponding runbook entry. Every cost has an optimization strategy.

The goal was never just to make Kubernetes manifests run — it was to build something you can **walk an interviewer through for 45 minutes** and demonstrate deep understanding at every layer.

**The project is now your portfolio. Own it.**

---

*Built over 20 days | Reference: [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac)*
