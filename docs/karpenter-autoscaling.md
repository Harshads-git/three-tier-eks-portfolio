# Next-Gen Node Autoscaling with Karpenter v1

> **Core Philosophy:** Stop managing static EC2 Auto Scaling Groups. Karpenter provisions right-sized compute directly via AWS Fleet APIs within seconds and continuously consolidates workloads to minimize cloud spend.

---

## 1. Karpenter vs Cluster Autoscaler (Why We Upgraded)

| Architectural Dimension | Legacy Cluster Autoscaler (CA) | Karpenter v1 (CloudForge EKS) |
|---|---|---|
| **Underlying Mechanism** | AWS EC2 Auto Scaling Groups (ASGs) | **Direct EC2 Fleet API calls (No ASGs)** |
| **Node Provisioning Speed** | 3 – 6 minutes (ASG scaling latency) | **30 – 45 seconds** |
| **Instance Type Flexibility** | Rigid (1 ASG per instance type / AZ) | **Dynamic (Evaluates 100+ instance types)** |
| **Bin-Packing Intelligence** | Basic | **Multi-dimensional bin-packing (CPU, RAM, Pods)** |
| **Cost Downscaling** | Only removes empty nodes | **Consolidates underutilized nodes automatically** |
| **Spot Interruption Handling** | Best-effort (often drops pods) | **Native SQS 2-min warning & proactive drain** |

---

## 2. Event-Driven Spot Interruption Lifecycle

Spot instances deliver **70% to 80% savings** compared to On-Demand, but AWS can reclaim them at any time with a 2-minute warning. 

CloudForge EKS couples Karpenter with an **SQS Interruption Queue** ([terraform/karpenter.tf](../terraform/karpenter.tf)) for zero-downtime Spot resilience:

```
┌─────────────────────────────────────────────────────────────┐
│                       AWS EC2 Cloud                         │
│                                                             │
│   AWS determines a Spot instance must be reclaimed...       │
│   • Publishes "EC2 Spot Instance Interruption Warning"      │
│   • 2-minute countdown timer starts (T - 120s)              │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 AWS EventBridge Event Rule                  │
│                                                             │
│   Pattern: { "source": ["aws.ec2"], "detail-type": [...] } │
└──────────────────────────────┬──────────────────────────────┘
                               │
            Routes event       ▼
┌─────────────────────────────────────────────────────────────┐
│              Karpenter SQS Interruption Queue               │
│               karpenter-interruption (FIFO/Standard)        │
└──────────────────────────────┬──────────────────────────────┘
                               │
               Long-polling    ▼
┌─────────────────────────────────────────────────────────────┐
│                 Karpenter Controller Pod                    │
│                                                             │
│   1. Receives interruption notification within 2 seconds    │
│   2. Immediately marks the victim node as Unschedulable     │
│      (kubectl cordon)                                       │
│   3. Proactively provisions a replacement Spot node         │
│      via ec2:CreateFleet API                                │
│   4. Gracefully evicts existing pods (kubectl drain),       │
│      honoring PodDisruptionBudgets (PDBs)                   │
│   5. New pods start on the replacement node BEFORE the old  │
│      node is terminated by AWS!                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Automated Cost Consolidation (`WhenEmptyOrUnderutilized`)

Traditional autoscalers only terminate a node when it reaches **0 pods**. If a node has a single lightweight pod using 5% CPU, that node stays alive forever, burning money.

### How Karpenter Consolidation Works:
1. **Continuous Calculation:** Every 30 seconds, Karpenter calculates whether the pods running across the cluster can be reorganized into fewer, cheaper nodes.
2. **Replacement:** If 3 underutilized `m5.large` instances ($0.096/hr each = $0.288/hr) can be replaced by 1 `c5.xlarge` Spot instance ($0.068/hr), Karpenter:
   - Provisions the cheaper instance.
   - Reschedules the pods onto it.
   - Deletes the 3 expensive instances.
3. **Net Result:** Continuous, hands-free cloud cost optimization without engineer intervention.

---

## 4. Node Configuration Specs

Our Karpenter setup is split into two declarative custom resources:

### 1. `EC2NodeClass` ([k8s/karpenter/ec2nodeclass.yaml](../k8s/karpenter/ec2nodeclass.yaml))
- **OS / AMI:** Amazon Linux 2023 (`AL2023`) optimized for EKS.
- **Storage:** 20Gi encrypted gp3 volumes with 3,000 IOPS and 125 MB/s throughput.
- **Security:** **IMDSv2 Mandatory** (`httpTokens: required`, hop limit: 2).
- **Subnet & Security Group Discovery:** Tag-based discovery via `karpenter.sh/discovery: three-tier-eks-cluster`.

### 2. `NodePool` ([k8s/karpenter/nodepool.yaml](../k8s/karpenter/nodepool.yaml))
- **Capacity Types:** `spot` prioritized, with automatic `on-demand` fallback.
- **Instance Families:** Compute (`c`), General Purpose (`m`), Burstable (`t`).
- **Disruption Budget:** Maximum 20% concurrent node disruptions.
- **Hard Cost Ceiling:** 100 CPU cores, 256GiB RAM.

---

## 5. SRE Day-2 Operations Cheat Sheet

```bash
# Check status of Karpenter NodePools and EC2NodeClasses
kubectl get nodepools,ec2nodeclasses

# Inspect all worker nodes dynamically provisioned by Karpenter
kubectl get nodes -l managed-by=karpenter -o wide

# Follow real-time Karpenter decision logs (bin-packing & provisioning)
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter -c controller

# Inspect current cluster capacity and resource utilization against limits
kubectl describe nodepool default
```
