# Interview Preparation Guide — Three-Tier EKS Portfolio

> This document prepares you to discuss every aspect of this project in technical interviews.
> Each section has the **question**, your **structured answer**, and **follow-up depth**.

---

## Category 1: Architecture & Design

### Q: "Walk me through the architecture of your project."

**Structured Answer (use STAR: Situation, Task, Action, Result)**:

> "I built a production-grade three-tier web application on AWS EKS to demonstrate end-to-end DevOps skills. The application is a task manager with a React frontend, Node.js API backend, and MongoDB database.
>
> **Infrastructure**: The cluster runs on AWS EKS with two t3.medium worker nodes across two availability zones, inside a VPC with private subnets for the worker nodes and public subnets for the load balancer. I used Terraform to provision everything — VPC, EKS, ECR, IAM roles — with an S3 backend for remote state.
>
> **Application**: The three tiers are containerized with Docker multi-stage builds and deployed as Kubernetes workloads. Frontend is Nginx serving the React app, Backend is Node.js Express handling the API, MongoDB is a StatefulSet with an EBS PersistentVolume.
>
> **Traffic flow**: Users hit an AWS Application Load Balancer, which routes `/api/*` requests to the backend and all other traffic to the frontend. This routing is managed by the AWS Load Balancer Controller in the cluster.
>
> **Automation**: The CI/CD pipeline uses GitHub Actions. CI runs tests, Trivy security scanning, and Kubernetes manifest validation. CD deploys with OIDC authentication — no stored AWS credentials anywhere. Terraform changes follow a Plan-on-PR, Apply-on-merge pattern."

---

### Q: "Why did you choose EKS over other compute options like ECS or Lambda?"

> "ECS is AWS-specific, which locks you into one vendor. K8s knowledge is transferable — the same skills work on GKE, AKS, or on-premises OpenShift. For this three-tier architecture, Kubernetes also gives me fine-grained control: I can set resource quotas per namespace, define NetworkPolicies for micro-segmentation between tiers, and use CRDs for Prometheus ServiceMonitors. Lambda would require re-architecting the stateful MongoDB connection handling. EKS was the right choice because it's what you'd actually use in a production SaaS company today."

---

### Q: "How does traffic get from the internet to a MongoDB write?"

**Answer** (draw this on a whiteboard or describe sequentially):

```
Browser → ALB (port 80)
  ALB listener rule: path /api/* → backend target group
  ALB → EC2 node IP : NodePort 30050
  kube-proxy iptables rule → backend pod IP : 5000
  Backend Express handler → MongoDB client.connect(mongo-service:27017)
  CoreDNS resolves mongo-service → ClusterIP → mongo-0 pod IP
  NetworkPolicy check: is backend pod allowed to reach mongo on 27017? YES
  MongoDB StatefulSet pod → /data/db (EBS volume)
```

> "Five network hops: internet → ALB → NodePort → ClusterIP → pod. The key detail is that with AWS VPC CNI, pods get real VPC IPs, so the ALB can talk directly to pods using `target-type: ip` mode — not going through the NodePort at all for traffic that's properly routed."

---

## Category 2: Kubernetes Deep Dives

### Q: "Explain how HPA works in your cluster."

> "The Metrics Server runs as a DaemonSet and collects CPU/memory metrics from kubelet every 30 seconds via the K8s resource metrics API. The HPA controller polls this API every 15 seconds and calculates desired replicas using: `ceil(currentReplicas × currentCPU / targetCPU)`. So with 2 replicas at 80% CPU and a target of 70%, it calculates `ceil(2 × 80/70) = ceil(2.28) = 3`.
>
> The HPA has two important timing windows: scale-up happens fast (no delay) but scale-down has a 5-minute stabilization window by default. That window prevents thrashing — without it, a brief load spike would trigger scale-up immediately followed by scale-down, creating constant pod churn.
>
> I validated HPA behavior with a k6 load test that ramps to 50 concurrent users. I watch `kubectl get hpa -w` during the test and see pods scale from 2 to 3-5 within 90 seconds of crossing the threshold."

---

### Q: "What is IRSA and why is it better than using EC2 instance profiles?"

> "IRSA — IAM Roles for Service Accounts — gives each Kubernetes ServiceAccount its own distinct AWS identity. The alternative, EC2 instance profiles, assigns one IAM role to the entire EC2 node, so ALL pods on that node share those permissions. That violates least-privilege: if the ALB Controller needs EC2 and ELB permissions, every pod on the node — including your application pods — could use those permissions too.
>
> With IRSA, the EKS OIDC provider issues a signed JWT to each pod. When the pod calls STS `AssumeRoleWithWebIdentity`, STS verifies the JWT signature and checks the trust policy's `StringLike` condition: `oidc-provider/sub = system:serviceaccount:kube-system:alb-controller`. Only the ALB Controller's ServiceAccount matches, so only that pod gets the ALB permissions. Credentials are temporary (1-hour TTL) and automatically rotated. There are no long-lived access keys stored anywhere."

---

### Q: "Explain NetworkPolicies — why did you implement them?"

> "By default, Kubernetes has no network isolation. Any pod in any namespace can communicate with any other pod — the compromised frontend pod could query MongoDB directly on port 27017. NetworkPolicies add firewall rules at the CNI level.
>
> I implemented a default deny-all policy that blocks all ingress and egress traffic for every pod in the three-tier namespace. Then I added explicit allow rules: ALB can reach frontend on port 80, frontend can reach backend on port 5000, and ONLY backend can reach MongoDB on port 27017. I also allow all pods to reach CoreDNS for DNS resolution — without this, service name resolution breaks.
>
> One critical gotcha: NetworkPolicies require the CNI's network policy agent to actually be enabled. With EKS and VPC CNI, you need to explicitly enable it with `aws eks update-addon vpc-cni --configuration-values '{"enableNetworkPolicy":"true"}'`. Without this, the policies are stored in etcd but completely ignored."

---

### Q: "What is a PodDisruptionBudget and when does it matter?"

> "A PDB tells Kubernetes the minimum number of pods that must remain available during voluntary disruptions — things like node drains, cluster autoscaler scale-down, or rolling node group upgrades for AMI updates. Without PDBs, the autoscaler could evict all pods of a Deployment simultaneously, causing downtime.
>
> I defined PDBs with `minAvailable: 1` for frontend and backend — with 2 replicas, this allows 1 pod to be disrupted at a time. For MongoDB with 1 replica, `minAvailable: 1` means 0 disruptions are allowed. `kubectl drain` will block until MongoDB can be safely rescheduled elsewhere first.
>
> The key distinction: PDBs only protect against voluntary disruptions. A hardware failure that kills the EC2 node bypasses PDB — Kubernetes just reschedules the pods automatically."

---

## Category 3: CI/CD & Security

### Q: "How does your CD pipeline authenticate to AWS without storing credentials?"

> "I use OIDC — OpenID Connect — federation between GitHub Actions and AWS. Here's the flow: GitHub Actions requests a JWT from GitHub's OIDC provider. This JWT contains claims about the workflow: the repository name, branch, commit SHA, and job ID. GitHub signs this JWT with its private key.
>
> The CD pipeline sends this JWT to AWS STS's `AssumeRoleWithWebIdentity` API. STS fetches GitHub's public key from the OIDC discovery URL and verifies the signature. Then it checks the IAM role's trust policy, which has a `StringLike` condition requiring the `sub` claim to match `repo:Harshads-git/three-tier-eks-portfolio:*`. This prevents any other repository from assuming this role.
>
> If the conditions match, STS returns temporary credentials valid for 1 hour. The pipeline uses these to push to ECR and call EKS APIs. When the job ends, the credentials expire and are gone. There are no access keys, no secrets, nothing to rotate or leak."

---

### Q: "Explain the concurrency settings in your GitHub Actions workflows."

> "I deliberately made them asymmetric based on the risk profile of each workflow:
>
> **CI** uses `cancel-in-progress: true`. When a developer pushes a new commit, the CI for the previous commit is cancelled immediately. This saves GitHub Actions minutes and keeps feedback fast. There's no risk — CI is idempotent.
>
> **CD** uses `cancel-in-progress: false`. If a deployment is in progress when a new CD run triggers, the new run queues instead of interrupting the running one. Interrupting a deployment mid-way leaves the cluster in a split state: some pods on the new image, some on the old one. That's worse than letting the current deploy finish.
>
> **Terraform** also uses `cancel-in-progress: false`. If you interrupt a `terraform apply`, the state file can be left in a partial write state, requiring manual `terraform state rm` surgery to fix. Never interrupt Terraform applies."

---

## Category 4: Monitoring & Observability

### Q: "How does Prometheus discover your application metrics?"

> "Prometheus in this cluster is deployed via the kube-prometheus-stack Helm chart, which includes the Prometheus Operator. The Operator introduces a CRD called ServiceMonitor. I created ServiceMonitor resources in the `three-tier` namespace that select services by label (`app: backend`). The Operator watches for these CRDs and automatically updates Prometheus's scrape configuration — no manual prometheus.yml editing required.
>
> For Prometheus to discover ServiceMonitors across all namespaces, I set `serviceMonitorNamespaceSelector: {}` in the Helm values. This is a common misconfiguration — if not set, Prometheus only discovers ServiceMonitors in its own namespace and ignores all your application monitors.
>
> I also defined a PrometheusRule CRD with 8 alert rules across 4 groups: pod availability, resource utilization, storage, and recording rules. The `for: 5m` duration on PodCrashLooping means the alert must be continuously true for 5 minutes before firing to AlertManager — this reduces false alarms from transient restarts."

---

### Q: "What are recording rules and why did you add them?"

> "Recording rules pre-compute expensive PromQL queries and store the result as a new time series. For example, calculating the error rate requires joining two rate() functions over the `http_requests_total` metric — that's CPU-intensive for Prometheus to compute on every dashboard panel load.
>
> With a recording rule, Prometheus evaluates the query once per minute and stores the result as `three_tier:backend_error_rate:5m`. Grafana then queries this pre-computed metric instead of running the expensive join every time. At scale — say, 50 engineers all viewing the same dashboard simultaneously — recording rules are essential. Without them, Prometheus becomes the performance bottleneck of your observability stack."

---

## Category 5: Infrastructure as Code

### Q: "Why does Terraform use an S3 backend with DynamoDB?"

> "Terraform tracks the state of your infrastructure in a `terraform.tfstate` file. Without a remote backend, this file sits on one developer's laptop. Problem: two developers run `terraform apply` simultaneously — they both read the same state, make conflicting changes, and corrupt the infrastructure.
>
> The S3 backend stores state in a shared, versioned S3 bucket. S3 versioning means every apply creates a new state version — if state gets corrupted, you can restore the previous version. DynamoDB provides state locking: before applying, Terraform writes a lock record to DynamoDB. If another apply is already running, it sees the lock and refuses to proceed. When the first apply completes, it removes the lock.
>
> I also keep sensitive variables (account IDs, cluster names) out of the state file's plaintext by using `sensitive = true` in variable definitions."

---

## Numbers Worth Memorizing

| Metric | Value | Why it matters |
|---|---|---|
| EKS control plane cost | $73/month | Always-on cost, drives destroy-when-idle strategy |
| t3.medium EC2 | $0.0416/hr on-demand, $0.0125/hr spot | Spot = 70% savings |
| HPA scale-up latency | 30-90 seconds | Time from threshold breach to traffic on new pod |
| HPA scale-down window | 5 minutes | Stabilization to prevent thrashing |
| Rolling update | maxSurge=1, maxUnavailable=0 | Zero-downtime: new pod ready before old terminated |
| IRSA token TTL | 1 hour | Auto-rotated, never stored |
| Trivy scan level | CRITICAL exits, HIGH warns | Trade-off: unfixable CVEs don't block merges |
| Terraform lock | DynamoDB item TTL | Prevents concurrent apply corruption |
| Prometheus retention | 30 days / 10 GiB | 30 days of metrics history |
| PDB minAvailable | 1 frontend/backend, 1 MongoDB | MongoDB=0 allowed disruptions with 1 replica |
