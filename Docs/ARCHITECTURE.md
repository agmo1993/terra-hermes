# System Architecture Diagram

This document contains Mermaid diagrams showing the terra-hermes AWS infrastructure.

---

## Complete System Architecture

```mermaid
flowchart TD
    subgraph COMPUTE["Compute (EC2)"]
        EC2["EC2 Instance\nt3.medium, Ubuntu 24.04\nAMI: Canonical SSM Parameter"]
        IAM_ROLE["IAM Instance Profile\nAmazonSSMManagedInstanceCore"]
        SG["Security Group\nPorts: 3000,4000,5000,5173,8000,8080,8443,8888"]
    end

    subgraph HERMES["Hermes Agent (on EC2)"]
        HERMES_USER["hermes user\nUID: 1000\nLinger enabled"]
        TELEGRAM_GW["Telegram Gateway\nsystemd --user service\nPolling mode"]
        CONFIG[".hermes/.env\nAPI keys, tokens"]
        SKILLS[".hermes/skills/\n(custom skills)"]
        MEMORIES[".hermes/memories/\nPersistent agent memory"]
    end

    subgraph EXTERNAL["External Services"]
        TELEGRAM["Telegram Bot API\nBotFather token"]
        USERS["Allowed Telegram Users\nNumeric IDs only"]
        MODEL_API["Model Provider API\nopenrouter / anthropic / openai /\nnvidia / gemini / opencode-go"]
    end

    subgraph OPS["Operator Access"]
        SSM["SSM Session Manager\nNo SSH, no open port 22"]
    end

    %% Boot + runtime
    EC2 --> IAM_ROLE
    EC2 --> SG
    EC2 -.->|user_data boot| HERMES_USER
    HERMES_USER --> TELEGRAM_GW
    HERMES_USER --> CONFIG
    HERMES_USER --> SKILLS
    HERMES_USER --> MEMORIES

    %% Conversation flow
    USERS -->|1. Message| TELEGRAM
    TELEGRAM -->|2. Long-poll| TELEGRAM_GW
    TELEGRAM_GW -->|3. Prompt| HERMES_USER
    HERMES_USER -->|4. Inference| MODEL_API
    MODEL_API -->|5. Completion| HERMES_USER
    HERMES_USER -->|6. Reply| TELEGRAM_GW
    TELEGRAM_GW -->|7. Push Message| TELEGRAM
    TELEGRAM -->|8. User Receives| USERS

    %% Operator
    SSM -.->|Session / RunShellScript| EC2
    IAM_ROLE -.->|Grants| SSM

    %% Styling
    classDef aws fill:#FF9900,color:#fff
    classDef hermes fill:#6C5CE7,color:#fff
    classDef external fill:#00CEC9,color:#fff
    classDef ops fill:#45B7D1,color:#fff

    class EC2,IAM_ROLE,SG aws
    class HERMES_USER,TELEGRAM_GW,CONFIG,SKILLS,MEMORIES hermes
    class TELEGRAM,USERS,MODEL_API external
    class SSM ops
```

---

## Bootstrap Flow (Sequence Diagram)

```mermaid
sequenceDiagram
    participant TF as Terraform
    participant EC2 as EC2 Instance
    participant Boot as cloud-init / hermes-startup.sh
    participant Hermes as Hermes CLI
    participant TG as Telegram Bot API

    Note over TF, TG: First boot after `terraform apply`

    TF->>EC2: RunInstances (user_data = env + startup script)
    EC2->>Boot: cloud-init executes user_data as root
    Boot->>Boot: Create `hermes` user, enable linger
    Boot->>Hermes: Install CLI as hermes user (never root)
    Boot->>Boot: Write ~/.hermes/.env (0600) with keys + tokens
    Boot->>Hermes: hermes config set model.provider / default / base_url
    Boot->>Hermes: hermes config check
    Boot->>Hermes: hermes tools enable vision
    Boot->>Hermes: hermes gateway install (systemd --user)
    Hermes->>TG: Begin long-polling with bot token
    Boot->>Boot: log "Hermes bootstrap complete"
```

---

## Infrastructure Deployment (Terraform Resources)

```mermaid
flowchart LR
    subgraph TF["Terraform State"]
        TF_VAR["terraform.tfvars\nsecrets.sh (TF_VAR_*)"]
        TF_STATE["terraform.tfstate\nLocal backend"]
    end

    subgraph PROVIDERS["Providers"]
        AWS["AWS Provider\nregion=us-east-1"]
    end

    subgraph MODULES["Resource Groups"]
        EC2_GRP["EC2 + IAM + SG\nmain.tf"]
        CATALOGUE["Provider catalogue\nproviders.tf"]
        BOOT["Bootstrap\ntemplates/hermes-startup.sh"]
    end

    subgraph OUTPUTS["Outputs"]
        OUT_INSTANCE["instance_id, public_ip, private_ip"]
        OUT_AZ["availability_zone"]
        OUT_SSM["ssm_session_command"]
    end

    TF_VAR --> TF_STATE
    TF_STATE --> AWS
    AWS --> EC2_GRP
    CATALOGUE --> BOOT
    EC2_GRP --> BOOT
    EC2_GRP --> OUT_INSTANCE
    EC2_GRP --> OUT_AZ
    EC2_GRP --> OUT_SSM
```

---

## Network & Security Boundaries

```mermaid
flowchart TD
    subgraph INTERNET["Internet (0.0.0.0/0)"]
        TG_API["Telegram Bot API\napi.telegram.org:443"]
        MODEL_API["Model Provider API\nHTTPS"]
        WEB_PORTS["Web Prototyping Ports\n3000,4000,5000,5173,8000,8080,8443,8888"]
    end

    subgraph VPC["Default VPC (172.31.0.0/16)"]
        subgraph PUBLIC["Public Subnets"]
            EC2_PUB["EC2 Instance\nPublic IP + Private IP"]
            IGW["Internet Gateway"]
        end
    end

    subgraph AWS_MANAGED["AWS Managed Services (No VPC)"]
        IAM_SVC["IAM"]
        SSM_SVC["SSM Session Manager"]
    end

    %% Connections
    EC2_PUB -->|HTTPS| TG_API
    EC2_PUB -->|HTTPS| MODEL_API
    WEB_PORTS -->|Security Group| EC2_PUB
    SSM_SVC -->|Session| EC2_PUB
    IAM_SVC -.->|Instance Profile| EC2_PUB

    %% VPC Flow
    IGW <--> EC2_PUB

    classDef internet fill:#FF6B6B,color:#fff
    classDef vpc fill:#4ECDC4,color:#fff
    classDef managed fill:#45B7D1,color:#fff

    class TG_API,MODEL_API,WEB_PORTS internet
    class EC2_PUB,IGW vpc
    class IAM_SVC,SSM_SVC managed
```

> **Note:** all listed inbound ports are open to `0.0.0.0/0` for prototyping
> convenience. There is no inbound SSH — operator access is via SSM Session
> Manager only. Use this on trusted, non-production accounts.

---

## Data Flow Summary

```mermaid
flowchart LR
    subgraph INPUT["Inputs"]
        TFVARS["terraform.tfvars\n- model_provider\n- model_name\n- telegram_allowed_users\n- instance_type / region"]
        SECRETS["secrets.sh\n- AWS creds\n- TF_VAR_provider_api_key\n- TF_VAR_telegram_bot_token\n- TF_VAR_github_token (optional)"]
    end

    subgraph DEPLOY["terraform apply"]
        PLAN["terraform plan"]
        APPLY["terraform apply"]
    end

    subgraph CREATED["Resources Created"]
        EC2_INST["EC2 Instance\n+ IAM Role + Instance Profile + SG"]
    end

    subgraph RUNTIME["Runtime (Post-Boot)"]
        HERMES_BOOT["Cloud-init → hermes-startup.sh"]
        MODEL_CFG["Model provider + base_url configured"]
        TG_GATEWAY["Telegram Gateway\nsystemd --user"]
    end

    INPUT --> DEPLOY
    DEPLOY --> CREATED
    CREATED --> RUNTIME

    classDef input fill:#FFE66D,color:#333
    classDef deploy fill:#FF9F1C,color:#fff
    classDef created fill:#6BCB77,color:#fff
    classDef runtime fill:#4D96FF,color:#fff

    class TFVARS,SECRETS input
    class PLAN,APPLY deploy
    class EC2_INST created
    class HERMES_BOOT,MODEL_CFG,TG_GATEWAY runtime
```

---

## How to Render

### VS Code / GitHub / GitLab
Mermaid renders natively in Markdown files.

### CLI (Mermaid CLI)
```bash
# Install
npm install -g @mermaid-js/mermaid-cli

# Render to SVG
mmdc -i Docs/ARCHITECTURE.md -o architecture.svg

# Render to PNG
mmdc -i Docs/ARCHITECTURE.md -o architecture.png -b transparent
```

### Online Editors
- [Mermaid Live Editor](https://mermaid.live/)
- [Markdown Preview Enhanced](https://shd101wyy.github.io/markdown-preview-enhanced/) (VS Code extension)

---

## Diagram Source

All diagrams are embedded in this Markdown file. To extract a specific diagram, copy the code block between `\`\`\`mermaid` and `\`\`\``.
