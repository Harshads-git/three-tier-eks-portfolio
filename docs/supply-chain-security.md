# Software Supply Chain Security — Keyless Cosign Signing, SBOM & Kyverno Attestation

> **Core Philosophy:** In zero-trust architecture, you must never trust an image simply because it resides in your container registry. Every container image must be cryptographically signed by your CI/CD pipeline, accompanied by a verified Software Bill of Materials (SBOM), and validated at cluster admission.

---

## 1. The Supply Chain Threat Landscape

Modern cloud-native attacks rarely target hardened firewalls; they compromise the **software supply chain**:
- **Compromised Registry / Man-in-the-Middle:** An attacker overwrites an existing container image in the registry with a malicious payload.
- **Dependency Confusion & Poisoning:** Malicious npm packages or malicious base image layers injected into third-party dependencies.
- **Time-Of-Check to Time-Of-Use (TOCTOU) Flaws:** An image tag passes security scanning, but is mutated before being pulled onto worker nodes.

To mitigate these threats, this repository implements **SLSA (Supply-chain Levels for Software Artifacts) Level 3** security controls.

---

## 2. Sigstore Cosign: Keyless Cryptographic Signing Architecture

Traditional container signing required generating long-lived GPG or asymmetric private keys. If the private key leaked, the entire chain of trust was compromised.

We implement **Keyless Signing** via the open-source **Sigstore** ecosystem:

```
┌─────────────────────────────────────────────────────────────┐
│             GitHub Actions CI Pipeline (.github)            │
│                                                             │
│   1. Build container image & push to Amazon ECR             │
│   2. Request short-lived OIDC token from GitHub             │
│      (Token claims: repository, workflow, ref, sha)         │
└──────────────────────────────┬──────────────────────────────┘
                               │
            Presents OIDC JWT  │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Sigstore Fulcio (Free Root CA)              │
│                                                             │
│   • Verifies GitHub OIDC JWT token                          │
│   • Generates a short-lived (10-minute) X.509 certificate   │
│   • Binds the certificate to Harshads-git/three-tier...     │
└──────────────────────────────┬──────────────────────────────┘
                               │
               Returns cert    │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                    Cosign CLI (In Runner)                   │
│                                                             │
│   • Signs container image digest with ephemeral keypair     │
│   • Ephemeral private key is IMMEDIATELY discarded          │
└──────────────────────────────┬──────────────────────────────┘
                               │
           Publishes signature │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│             Sigstore Rekor (Transparency Log)               │
│                                                             │
│   • Records signature, certificate, and timestamp into an   │
│     immutable, append-only cryptographic Merkle tree        │
│   • Provides non-repudiation and public auditability        │
└─────────────────────────────────────────────────────────────┘
```

### Why Keyless is Superior:
- **Zero Stored Secrets:** No private keys exist in GitHub Secrets or AWS KMS.
- **No Key Rotation:** Certificates expire in 10 minutes; validation relies on the immutable Rekor log timestamp.
- **Identity-Centric:** Signatures are tied directly to the exact git commit, branch, and GitHub Actions workflow execution.

---

## 3. Software Bill of Materials (SBOM) with Syft & CycloneDX

An **SBOM** is a complete, machine-readable inventory of all software components, dependencies, and OS libraries packaged inside a container.

In our supply chain pipeline:
1. **Generation:** Anchore **Syft** analyzes the final multi-stage image layers and generates a **CycloneDX JSON** SBOM.
2. **Attestation:** Cosign cryptographically signs and attaches the SBOM directly to the ECR image manifest:
   ```bash
   cosign attest --yes \
     --type cyclonedx \
     --predicate sbom-backend.json \
     <account>.dkr.ecr.us-east-1.amazonaws.com/three-tier-backend:sha-xxxx
   ```
3. **Auditability:** Security and compliance teams can query the container's exact dependencies without running or extracting the container image.

---

## 4. Admission Control Verification via Kyverno

Generating signatures in CI is useless without runtime admission gates. 

Our Kyverno policy ([k8s/kyverno/policies/verify-image-signatures.yaml](../k8s/kyverno/policies/verify-image-signatures.yaml)) intercepts every Pod creation request at the Kubernetes API boundary:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-ecr-signatures
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [three-tier]
      verifyImages:
        - imageReferences:
            - "*.dkr.ecr.*.amazonaws.com/*"
          mutateDigest: true
          attestors:
            - entries:
                - keyless:
                    issuer: https://token.actions.githubusercontent.com
                    subject: "https://github.com/Harshads-git/three-tier-eks-portfolio/.github/workflows/supply-chain.yml@refs/heads/main"
                    rekor:
                      url: https://rekor.sigstore.dev
```

### The `mutateDigest: true` Defense
Notice the `mutateDigest: true` setting:
- If a deployment specifies `image: three-tier-backend:sha-abc1234`, Kyverno resolves and replaces the tag with its immutable SHA256 digest:
  `three-tier-backend@sha256:7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069`
- This guarantees that even if an attacker attempts to mutate an image tag between admission and container pulling on worker nodes, the container runtime will reject it.

---

## 5. Verification Commands Cheat Sheet

```bash
# Verify container image signature manually using Cosign CLI
cosign verify \
  --certificate-identity-regexp "https://github.com/Harshads-git/three-tier-eks-portfolio/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  <IMAGE_URI>

# Download and view the cryptographically signed SBOM from ECR
cosign download attestation <IMAGE_URI> | jq -r '.payload' | base64 -d | jq .

# Generate SBOM locally for offline vulnerability inspection
chmod +x scripts/generate-sbom.sh
./scripts/generate-sbom.sh three-tier-backend:local
```
