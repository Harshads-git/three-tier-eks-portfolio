# Enterprise Secrets Management — External Secrets Operator (ESO) & AWS Secrets Manager

> **Core Philosophy:** Secrets must never touch Git, even in base64 format. Secrets belong in a dedicated, audited Key Management Service (AWS Secrets Manager) and are synchronized into Kubernetes ephemeral memory dynamically via IAM Roles for Service Accounts (IRSA).

---

## 1. Why Native Kubernetes Secrets Fail Enterprise Compliance

A standard Kubernetes Secret looks like this:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mongo-secret
data:
  password: cGFzc3dvcmQxMjM=
```

### The Three Critical Security Flaws:
1. **Base64 is NOT Encryption:** Running `echo "cGFzc3dvcmQxMjM=" | base64 -d` yields `password123` instantly. Anyone with read access to the namespace or git repository has the plaintext secret.
2. **Configuration Drift & Stale Credentials:** Rotating passwords requires manual `kubectl apply` commands across environments, causing downtime or missed updates.
3. **No Audit Trail:** Kubernetes audit logs rarely capture which individual application instance accessed a specific secret value, failing SOC 2 and PCI-DSS compliance audits.

---

## 2. Architecture: AWS Secrets Manager + ESO + IRSA

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS Cloud (Control Plane)                │
│                                                             │
│   AWS Secrets Manager                                       │
│   ├── three-tier/production/mongodb                         │
│   │   └── { "username": "admin", "password": "..." }        │
│   └── three-tier/production/backend                         │
│       └── { "jwt_secret": "..." }                           │
│                                                             │
│   AWS KMS (Key Management Service)                          │
│   └── Envelope Encryption (AES-256-GCM)                     │
│                                                             │
│   AWS CloudTrail ─── Logs every secret retrieval API call   │
└──────────────────────────────▲──────────────────────────────┘
                               │
                AWS STS AssumeRoleWithWebIdentity
             (IRSA: external-secrets-sa OIDC JWT)
                               │
┌──────────────────────────────┴──────────────────────────────┐
│                    Amazon EKS Cluster                       │
│                                                             │
│  ┌──────────────── Namespace: external-secrets ──────────┐  │
│  │                                                       │  │
│  │   External Secrets Operator Controller                │  │
│  │   ├── Uses ServiceAccount: external-secrets-sa        │  │
│  │   └── Bound to ClusterSecretStore: aws-secrets-manager│  │
│  │                                                       │  │
│  └───────────────────────────┬───────────────────────────┘  │
│                              │ Synchronizes every 1h
│                              ▼
│  ┌──────────────── Namespace: three-tier ────────────────┐  │
│  │                                                       │  │
│  │   ExternalSecret: mongo-external-secret               │  │
│  │          │                                            │  │
│  │          ▼ (Dynamically created & managed)            │  │
│  │   Native Kubernetes Secret: mongo-secret              │  │
│  │          │                                            │  │
│  │          ▼ Injected via secretKeyRef                  │  │
│  │   Pods: backend (Express API) & mongo-0 (StatefulSet) │  │
│  │                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. How the Authentication Flow Works (Zero Stored Keys)

1. The ESO controller pod starts up in the `external-secrets` namespace.
2. Kubernetes projects an **OIDC JWT service account token** into `/var/run/secrets/kubernetes.io/serviceaccount/token`.
3. ESO calls `sts:AssumeRoleWithWebIdentity`, passing this token to AWS STS.
4. AWS STS verifies the token with the EKS OIDC Issuer (`https://oidc.eks.us-east-1.amazonaws.com/id/...`).
5. STS confirms the caller is `system:serviceaccount:external-secrets:external-secrets-sa` and returns temporary, short-lived AWS credentials (valid for 1 hour).
6. ESO calls `secretsmanager:GetSecretValue` to fetch the encrypted payload from AWS Secrets Manager.
7. ESO decrypts the secret in memory and writes it into the target native Kubernetes Secret (`mongo-secret`).
8. **Result:** No human, runner, or git repository ever stores or handles the AWS access keys or plaintext passwords.

---

## 4. Automated Secret Rotation Without Downtime

When a database password is rotated in AWS Secrets Manager:
1. **Detection:** Within the `refreshInterval: "1h"` window (or immediately upon manual trigger), ESO queries AWS Secrets Manager.
2. **Reconciliation:** ESO detects a new version ID and immediately overwrites the data in `mongo-secret`.
3. **Application Reload:**
   - For applications utilizing volume mounts, Kubernetes automatically updates the mounted files within ~60 seconds.
   - For applications using environment variables (`envFrom` or `secretKeyRef`), tools like Stakater Reloader trigger a zero-downtime rolling update of the backend pods.

---

## 5. Day-2 SRE Operations with ESO CLI

```bash
# Check status of the ClusterSecretStore
kubectl get clustersecretstores

# Inspect all ExternalSecrets and their synchronization status
kubectl get externalsecrets -n three-tier

# Describe an ExternalSecret to debug synchronization errors
kubectl describe externalsecret mongo-external-secret -n three-tier

# Force an immediate resynchronization without waiting for the 1h interval
kubectl annotate externalsecret mongo-external-secret -n three-tier force-sync=$(date +%s) --overwrite

# Verify the generated native secret exists and has required keys
kubectl get secret mongo-secret -n three-tier
```
