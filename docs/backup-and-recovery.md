# Enterprise Backup & Disaster Recovery with Velero

> **Platform Pillar:** Business Continuity, Disaster Recovery & State Replication (Day 29)  
> **Tooling:** Velero v1.14+, AWS S3, AWS EBS CSI Snapshotter, AWS IAM IRSA

---

## 1. Executive Summary & Strategy

In an enterprise Kubernetes platform, code and configuration are declaratively managed in Git (GitOps), but **state, persistent volumes, and runtime secrets** require dedicated data protection pipelines. 

The **CloudForge EKS Platform** implements automated, production-grade backup and disaster recovery using **Velero**:
- **Metadata Protection:** etcd cluster states, Custom Resource Definitions (CRDs), Helm release metadata, Secrets, ConfigMaps, and Ingress rules are backed up directly to a dedicated, encrypted AWS S3 bucket.
- **Persistent Volume Protection:** PersistentVolumeClaims (PVCs)—such as the MongoDB transactional database volume—are snapshot using native AWS EBS CSI VolumeSnapshots via AWS EC2 APIs.
- **Zero Static Credentials:** Velero authenticates to AWS via IAM Roles for Service Accounts (IRSA), eliminating all access key rotation overhead and exposure risks.

```
┌────────────────────────────────────────────────────────────────────────┐
│                   VELERO DISASTER RECOVERY PIPELINE                    │
│                                                                        │
│  EKS Cluster (Namespace: three-tier)                                   │
│  ┌───────────────────────┐                                             │
│  │ MongoDB (PVC / EBS)   │───EBS CSI Snapshot───▶ AWS EBS Snapshots    │
│  ├───────────────────────┤                        (gp3 Volume State)   │
│  │ Backend / Frontend    │                                             │
│  │ K8s Manifests/Secrets │───Velero Daemon──────▶ AWS S3 Bucket        │
│  └───────────────────────┘                        (Encrypted & Versioned│
│                                                    30d IA / 90d Prune) │
│                                                                        │
│  Disaster Outage / Region Evacuation:                                  │
│  S3 + EBS Snapshots ───▶ velero restore ───▶ Target EKS Cluster (RTO < 15m)│
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Business Continuity Metrics: RTO & RPO

CloudForge EKS establishes the following Service Level Agreements (SLAs) for business continuity:

| Metric | Target SLA | Implementation Architecture |
|---|---|---|
| **RPO (Recovery Point Objective)** | **< 24 Hours** (Automated)<br>**< 5 Minutes** (Pre-Deployment) | Daily cron schedule (`0 2 * * *`) captures point-in-time state; on-demand triggers before critical migrations. |
| **RTO (Recovery Time Objective)** | **< 15 Minutes** (Full Namespace Restore)<br>**< 30 Minutes** (Entire Cluster Loss) | Declarative Velero restoration restores PersistentVolume claims, mounts EBS snapshots, and spins up pods. |
| **Data Retention** | **90 Days** | S3 Lifecycle: 30 days active in Standard, transitioned to Standard-IA, pruned automatically at 90 days. |
| **Encryption Standard** | **AES-256 (SSE-S3)** | S3 default server-side encryption with bucket-level versioning and strict public access block. |

---

## 3. Architecture & Cloud Infrastructure

### S3 & IAM Configuration (`terraform/velero.tf`)
The Terraform configuration provisions:
1. **Encrypted S3 Bucket:** `three-tier-eks-cluster-velero-backups-<ACCOUNT_ID>` with strict public access blocks and lifecycle rules.
2. **Least-Privilege IAM Policy:** Scoped permissions for S3 bucket actions (`s3:PutObject`, `s3:GetObject`, `s3:ListBucket`) and EC2 volume snapshots (`ec2:CreateSnapshot`, `ec2:DescribeVolumes`, etc.).
3. **IRSA Trust Relationship:** Web identity federation bound to `system:serviceaccount:velero:velero-server`.

### Kubernetes & Operator Manifests (`k8s/backup/`)
The declarative backup stack includes:
- `namespace.yaml`: Isolated `velero` administrative namespace.
- `serviceaccount.yaml`: ServiceAccount annotated with the AWS IRSA Role ARN.
- `backup-storage-location.yaml`: CRD defining the S3 target bucket and AWS region (`us-east-1`).
- `volume-snapshot-location.yaml`: CRD configuring native AWS EBS volume snapshot plugins.
- `schedule-daily.yaml`: Automated daily cron schedule with 720-hour (30-day) TTL.
- `values.yaml`: Production Helm configuration bundling `velero-plugin-for-aws:v1.9.2`.

---

## 4. Operational Playbook & Procedures

### Taking an On-Demand Backup
Before major database migrations or infrastructure upgrades, trigger an immediate backup:

```bash
# Create immediate ad-hoc backup of the entire three-tier namespace
velero backup create pre-upgrade-backup-$(date +%Y%m%d) \
  --include-namespaces three-tier \
  --snapshot-volumes=true \
  --wait

# Inspect backup status and resource counts
velero backup describe pre-upgrade-backup-$(date +%Y%m%d) --details
```

### Inspecting Existing Backups
```bash
# List all available snapshots in S3
velero backup get

# Inspect daily schedule execution history
velero schedule get
```

### Restoring from Backup (Namespace Disaster Recovery)
If the application namespace experiences corruption or accidental deletion:

```bash
# Execute full restore from the latest backup
velero restore create --from-backup <BACKUP_NAME> --wait

# Monitor restoration progress
velero restore describe <RESTORE_NAME>

# Verify application readiness
kubectl get pods,pvc -n three-tier
```

---

## 5. Automated Disaster Recovery Drill (`scripts/disaster-recovery-drill.sh`)

CloudForge EKS provides an automated disaster recovery test harness to validate RTO compliance without risking production downtime:

```bash
# Run simulated disaster recovery drill (dry-run mode)
./scripts/disaster-recovery-drill.sh --dry-run

# Run live drill against staging cluster (destroys & restores namespace)
./scripts/disaster-recovery-drill.sh --live
```

### Drill Execution Lifecycle:
1. **Pre-flight Audit:** Asserts presence of `velero`, `kubectl`, and validates active PVC bindings.
2. **Snapshot Creation:** Generates a unique drill backup (`dr-drill-<timestamp>`).
3. **Failure Simulation:** Simulates complete data center / namespace loss (`kubectl delete namespace three-tier`).
4. **Automated Restoration:** Triggers Velero restore, rebinds EBS volumes, and watches pods return to `Running`.
5. **RTO Audit Report:** Measures elapsed restoration seconds and outputs an executive scorecard.
