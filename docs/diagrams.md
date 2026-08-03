# Architecture Diagrams (Mermaid)

> Copy any diagram block into [mermaid.live](https://mermaid.live) to render it.
> These are also auto-rendered in GitHub Markdown.

---

## Diagram 1 — AWS Infrastructure Overview

```mermaid
graph TB
    Internet([🌐 Internet]) --> ALB

    subgraph AWS["☁️ AWS Cloud — us-east-1"]
        subgraph VPC["🔒 VPC: 10.0.0.0/16"]

            subgraph PubSubnets["Public Subnets (10.0.101.0/24, 10.0.102.0/24)"]
                ALB[("⚡ ALB\nApplication Load Balancer")]
                NAT["🌐 NAT Gateway"]
            end

            subgraph PrivSubnets["Private Subnets (10.0.1.0/24, 10.0.2.0/24)"]
                subgraph Node1["EC2 t3.medium (us-east-1a)"]
                    FE1["🖥️ frontend\nnginx:alpine"]
                    BE1["⚙️ backend\nnode:18-alpine"]
                    MONGO["🗄️ mongo-0\nmongodb:6.0"]
                end
                subgraph Node2["EC2 t3.medium (us-east-1b)"]
                    FE2["🖥️ frontend\nnginx:alpine"]
                    BE2["⚙️ backend\nnode:18-alpine"]
                    HPA_PODS["📈 HPA pods\n(2-5 replicas)"]
                end
            end

            subgraph EBS_Volumes["💾 EBS Volumes"]
                MONGO_VOL["MongoDB PVC\n5 GiB gp2"]
                PROM_VOL["Prometheus\n10 GiB gp2"]
            end

        end

        subgraph Registry["Container Registry"]
            ECR_BE["📦 ECR\nbackend\nIMMUTABLE"]
            ECR_FE["📦 ECR\nfrontend\nIMMUTABLE"]
        end

        subgraph State["Terraform State"]
            S3["🪣 S3 Bucket\nTF State\n(versioned)"]
            DDB["🔒 DynamoDB\nState Lock"]
        end

        EKS_CP["☸️ EKS Control Plane\n(AWS managed)\nv1.29, 3 AZ HA"]
    end

    ALB -->|"/api/*\nport 5000"| BE1
    ALB -->|"/*\nport 80"| FE1
    ALB -->|"/*\nport 80"| FE2
    ALB -->|"/api/*\nport 5000"| BE2
    BE1 --> MONGO
    BE2 --> MONGO
    MONGO --- MONGO_VOL
    Node1 -->|NAT egress| NAT
    Node2 -->|NAT egress| NAT
    NAT --> Internet
    EKS_CP -->|manages| Node1
    EKS_CP -->|manages| Node2
```

---

## Diagram 2 — CI/CD Pipeline Flow

```mermaid
flowchart TD
    Dev["👨‍💻 Developer\npushes code"] --> PR["📋 Pull Request\nto main"]

    PR --> CI["🔄 CI Workflow\nci.yml"]

    subgraph CI_Jobs["CI Jobs (parallel)"]
        TEST_BE["✅ test-backend\nnpm test, lint"]
        TEST_FE["✅ test-frontend\nnpm test --watchAll=false"]
        VALIDATE["✅ validate-manifests\nkubeconform"]
    end

    CI --> CI_Jobs

    subgraph BUILD_SCAN["Build & Scan (parallel matrix)"]
        BUILD_BE["🐳 Build backend\nDockerfile"]
        BUILD_FE["🐳 Build frontend\nDockerfile"]
        TRIVY_BE["🔒 Trivy scan\nbackend image"]
        TRIVY_FE["🔒 Trivy scan\nfrontend image"]
    end

    CI_Jobs --> BUILD_SCAN
    BUILD_BE --> TRIVY_BE
    BUILD_FE --> TRIVY_FE

    TRIVY_BE -->|"CRITICAL CVE?\nFail PR"| GATE{CI Gate}
    TRIVY_FE -->|"CRITICAL CVE?\nFail PR"| GATE

    GATE -->|"✅ All pass"| MERGE["🔀 Merge to main"]
    GATE -->|"❌ Fails"| BLOCK["🚫 PR Blocked"]

    MERGE --> CD["🚀 CD Workflow\ncd.yml"]

    subgraph CD_Jobs["CD Jobs"]
        SET_TAG["🏷️ Set image tag\nsha-a1b2c3d"]
        PUSH_BE["📤 Push backend\nto ECR\n(OIDC auth)"]
        PUSH_FE["📤 Push frontend\nto ECR\n(OIDC auth)"]
        DEPLOY["⎈ Deploy to EKS\nkubectl set image\nRolling update"]
        VERIFY["✔️ Verify rollout\nkubectl rollout status\ntimeout: 300s"]
    end

    CD --> SET_TAG
    SET_TAG --> PUSH_BE
    SET_TAG --> PUSH_FE
    PUSH_BE --> DEPLOY
    PUSH_FE --> DEPLOY
    DEPLOY --> VERIFY

    VERIFY -->|"✅ Success"| SUCCESS["🎉 Deployed!\nALB URL printed"]
    VERIFY -->|"❌ Timeout"| ROLLBACK["🔄 Auto rollback\nkubectl rollout undo"]
```

---

## Diagram 3 — Kubernetes Namespace Topology

```mermaid
graph TB
    subgraph K8s["☸️ Kubernetes Cluster"]

        subgraph ThreeTier["three-tier namespace"]
            subgraph FrontendTier["Frontend Tier"]
                FE_DEP["Deployment\nfrontend\nreplicas: 2-5"]
                FE_SVC["Service\nfrontend-service\nNodePort:30080"]
                FE_HPA["HPA\nfrontend-hpa\ncpu: 70%"]
                FE_PDB["PDB\nfrontend-pdb\nminAvailable: 1"]
            end

            subgraph BackendTier["Backend Tier"]
                BE_DEP["Deployment\nbackend\nreplicas: 2-5"]
                BE_SVC["Service\nbackend-service\nNodePort:30050"]
                BE_HPA["HPA\nbackend-hpa\ncpu: 70%"]
                BE_PDB["PDB\nbackend-pdb\nminAvailable: 1"]
                BE_CM["ConfigMap\nbackend-config\nMONGO_URI etc"]
            end

            subgraph DataTier["Data Tier"]
                MONGO_SS["StatefulSet\nmongo\nreplicas: 1"]
                MONGO_SVC["Service\nmongo-service\nClusterIP:27017"]
                MONGO_PVC["PVC\nmongo-data\n5Gi gp2"]
                MONGO_PDB["PDB\nmongo-pdb\nminAvailable: 1"]
                MONGO_SEC["Secret\nmongo-secret\ncredentials"]
            end

            ING["Ingress\nthree-tier-ingress\nalb class\n/ → frontend\n/api → backend"]

            NP_DENY["NetworkPolicy\ndeny-all\n(default deny)"]
            NP_ALLOW["NetworkPolicy\nallow-ingress\n(explicit allows)"]

            RQ["ResourceQuota\n2 CPU, 1Gi RAM\nno LoadBalancer"]
            LR["LimitRange\ndefaults injected"]
        end

        subgraph KubeSystem["kube-system namespace"]
            COREDNS["CoreDNS\n(service discovery)"]
            METRICS["Metrics Server\n(HPA metrics)"]
            ALB_CTRL["ALB Controller\n(provisions AWS ALB)"]
            CA["Cluster Autoscaler\n(scales EC2 nodes)"]
        end

        subgraph Monitoring["monitoring namespace"]
            PROMETHEUS["Prometheus\n10Gi EBS, 30d retention"]
            GRAFANA["Grafana\n2Gi EBS"]
            ALERTMGR["AlertManager\n2Gi EBS"]
            SM_BE["ServiceMonitor\nbackend"]
            SM_FE["ServiceMonitor\nfrontend"]
            PRULE["PrometheusRule\n8 custom alerts"]
        end
    end

    FE_DEP --> FE_SVC
    FE_HPA -->|"scales"| FE_DEP
    FE_PDB -->|"protects"| FE_DEP

    BE_DEP --> BE_SVC
    BE_HPA -->|"scales"| BE_DEP
    BE_PDB -->|"protects"| BE_DEP

    MONGO_SS --> MONGO_SVC
    MONGO_SS --- MONGO_PVC
    MONGO_PDB -->|"protects"| MONGO_SS

    ING -->|"/ → "| FE_SVC
    ING -->|"/api → "| BE_SVC
    BE_DEP -->|"mongo-service:27017"| MONGO_SVC

    PROMETHEUS -->|"scrapes"| SM_BE
    PROMETHEUS -->|"scrapes"| SM_FE
    PROMETHEUS -->|"evaluates"| PRULE
    PROMETHEUS -->|"fires alerts"| ALERTMGR
    GRAFANA -->|"queries"| PROMETHEUS
```

---

## Diagram 4 — IRSA Authentication Flow

```mermaid
sequenceDiagram
    participant Pod as "☸️ ALB Controller Pod"
    participant K8s as "K8s API"
    participant EKS as "EKS OIDC Provider"
    participant STS as "AWS STS"
    participant IAM as "AWS IAM"
    participant EC2 as "AWS EC2/ELB"

    Note over Pod,K8s: Pod starts, K8s webhook injects OIDC token
    Pod->>K8s: Get ServiceAccount token
    K8s-->>Pod: Signed JWT (audience: sts.amazonaws.com)
    Note over Pod: Token stored at:<br/>/var/run/secrets/eks.amazonaws.com/<br/>serviceaccount/token

    Note over Pod,STS: Pod makes first AWS API call
    Pod->>STS: AssumeRoleWithWebIdentity(JWT, role-arn)
    STS->>EKS: Verify JWT signature
    EKS-->>STS: JWT valid (issuer matches OIDC provider)
    STS->>IAM: Check trust policy conditions
    IAM-->>STS: sub=system:serviceaccount:kube-system:alb-controller ✅
    STS-->>Pod: Temporary credentials (1hr max)
    Note over Pod: AccessKeyId + SecretAccessKey + SessionToken<br/>Valid for 1 hour, auto-refreshed

    Pod->>EC2: CreateLoadBalancer(...) with temp credentials
    EC2-->>Pod: ALB created ✅
```

---

## Diagram 5 — HPA Scaling Decision Flow

```mermaid
flowchart TD
    MS["📊 Metrics Server\ncollects pod CPU every 30s"]
    HPA["📈 HPA Controller\nevaluates every 15s"]
    CALC["🧮 Calculate desired replicas:\nceil(currentReplicas × currentCPU/targetCPU)\nexample: ceil(2 × 80%/70%) = ceil(2.28) = 3"]
    
    MS -->|"CPU metrics"| HPA
    HPA --> CALC

    CALC -->|"desired > current\nAND above threshold 3min"| SCALEUP["⬆️ Scale Up\nCreate new pod\n30-90s to Ready"]
    CALC -->|"desired < current\nAND below threshold 5min\n(stabilization window)"| SCALEDOWN["⬇️ Scale Down\nDelete pod\n(PDB check first)"]
    CALC -->|"desired == current"| NOOP["✅ No Action\nCurrent replicas OK"]

    SCALEUP --> PDB_CHECK_UP["PDB Check\nIs minAvailable satisfied\nafter adding pod?"]
    SCALEDOWN --> PDB_CHECK["PDB Check\nIs minAvailable satisfied\nafter removing pod?"]
    
    PDB_CHECK -->|"YES: proceed"| EVICT["Evict pod\nGraceful termination\n(SIGTERM → 30s)"]
    PDB_CHECK -->|"NO: block"| WAIT["⏳ Wait\nCannot scale down\nuntil new pod Ready"]
    
    EVICT --> CA_CHECK["Cluster Autoscaler\nNode underutilized?\n(<50% for 10min)"]
    CA_CHECK -->|"YES"| NODE_DOWN["⬇️ Terminate EC2 node\n(drain pods first)"]
    CA_CHECK -->|"NO"| STABLE["✅ Stable\nNode stays"]
```
