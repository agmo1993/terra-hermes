# System Architecture Diagram

This document contains Mermaid diagrams showing the terra-hermes AWS infrastructure with SES email integration.

---

## Complete System Architecture

```mermaid
flowchart TD
    subgraph DNS["Route 53 (Your Existing Hosted Zone)"]
        MX["MX Record\n@ → inbound-smtp.us-east-1.amazonaws.com"]
        TXT_VER["TXT _amazonses\nVerification Token"]
        DKIM1["CNAME dkim1._domainkey\n→ dkim1.dkim.amazonses.com"]
        DKIM2["CNAME dkim2._domainkey\n→ dkim2.dkim.amazonses.com"]
        DKIM3["CNAME dkim3._domainkey\n→ dkim3.dkim.amazonses.com"]
        SPF["TXT @\nv=spf1 include:amazonses.com ~all"]
        DMARC["TXT _dmarc\nv=DMARC1; p=quarantine; rua=mailto:dmarc@..."]
    end

    subgraph SES["Amazon SES (us-east-1)"]
        IDENTITY["Domain Identity\nhermes.example.com"]
        DKIM_VER["DKIM Verification\n(3 CNAME tokens)"]
        RECEIPT_RULE["Receipt Rule Set\nhermes-email-rules"]
        RULE_STORE["Rule: store-and-notify\nTLS: Require\nRecipients: @hermes.example.com"]
        ACTION_S3["S3 Action\nBucket: hermes-emails-prod\nPrefix: incoming/"]
        ACTION_SNS["SNS Action\nTopic: hermes-email-received"]
    end

    subgraph STORAGE["Storage Layer"]
        S3["S3 Bucket\nhermes-emails-prod\nSSE-AES256, Versioned\nLifecycle: 90 days"]
        DDB["DynamoDB Table\nhermes-email-metadata\nPK: message_id\nTTL: 90 days"]
    end

    subgraph EVENTS["Event Processing"]
        SNS["SNS Topic\nhermes-email-received"]
        LAMBDA["Lambda: hermes-email-processor\nPython 3.11, 256MB, 60s\nVPC: Default (for EC2 access)"]
    end

    subgraph COMPUTE["Compute (EC2)"]
        EC2["EC2 Instance\nt3.medium, Ubuntu 24.04\nAMI: Canonical SSM Parameter"]
        IAM_ROLE["IAM Instance Profile\nAmazonSSMManagedInstanceCore"]
        SG["Security Group\nPorts: 3000,4000,5000,5173,8000,8080,8443,8888"]
    end

    subgraph HERMES["Hermes Agent (on EC2)"]
        HERMES_USER["hermes user\nUID: 1000\nLinger enabled"]
        TELEGRAM_GW["Telegram Gateway\nsystemd --user service\nPolling mode"]
        WEBHOOK["Email Webhook Skill\nHTTP :8000/webhook/email\nHMAC-SHA256 verified"]
        EMAILS_JSONL["~/.hermes/emails.jsonl\nEmail memory store"]
        SES_TOOL["SES Send Email Tool\nsend_email(to, subject, body, html?)"]
        CONFIG[".hermes/.env\nAPI keys, tokens"]
        SKILLS[".hermes/skills/\n- hermes-email-webhook\n- ses-send-email\n- (custom skills)"]
        MEMORIES[".hermes/memories/\nPersistent agent memory"]
    end

    subgraph EXTERNAL["External Services"]
        TELEGRAM["Telegram Bot API\nBotFather token"]
        USERS["Allowed Telegram Users\nNumeric IDs only"]
        SES_SEND["SES SendEmail API\nOutbound emails"]
    end

    %% Email Flow
    INTERNET["Internet Email\n(SMTP)"] -->|1. Incoming Email| SES
    SES -->|2. Receipt Rule| ACTION_S3
    SES -->|3. Receipt Rule| ACTION_SNS
    ACTION_S3 -->|4. Store .eml| S3
    ACTION_SNS -->|5. Publish Event| SNS
    SNS -->|6. Trigger| LAMBDA
    LAMBDA -->|7. Fetch .eml| S3
    LAMBDA -->|8. Parse & Store Metadata| DDB
    LAMBDA -->|9. POST Webhook| WEBHOOK
    WEBHOOK -->|10. Store & Notify| EMAILS_JSONL
    WEBHOOK -->|11. Telegram Notify| TELEGRAM_GW
    TELEGRAM_GW -->|12. Push Message| TELEGRAM
    TELEGRAM -->|13. User Receives| USERS

    %% Outbound Flow
    HERMES_USER -->|User Command| SES_TOOL
    SES_TOOL -->|SendEmail| SES_SEND
    SES_SEND -->|Deliver| INTERNET

    %% Infrastructure
    DNS -.->|Auto-created by TF| SES
    EC2 --> IAM_ROLE
    EC2 --> SG
    EC2 -.->|user_data boot| HERMES_USER
    HERMES_USER --> TELEGRAM_GW
    HERMES_USER --> WEBHOOK
    HERMES_USER --> SES_TOOL
    HERMES_USER --> CONFIG
    HERMES_USER --> SKILLS
    HERMES_USER --> MEMORIES
    HERMES_USER --> EMAILS_JSONL

    %% IAM for Lambda
    LAMBDA -.->|IAM Role| SES_SEND
    LAMBDA -.->|IAM Role| S3
    LAMBDA -.->|IAM Role| DDB

    %% Styling
    classDef aws fill:#FF9900,color:#fff
    classDef hermes fill:#6C5CE7,color:#fff
    classDef storage fill:#00B8D9,color:#fff
    classDef external fill:#00CEC9,color:#fff
    classDef dns fill:#FD79A8,color:#fff

    class SES,S3,DDB,SNS,LAMBDA,EC2,IAM_ROLE,SG aws
    class HERMES_USER,TELEGRAM_GW,WEBHOOK,EMAILS_JSONL,SES_TOOL,CONFIG,SKILLS,MEMORIES hermes
    class DNS dns
    class TELEGRAM,USERS,SES_SEND external
```

---

## Email Receive Flow (Sequence Diagram)

```mermaid
sequenceDiagram
    participant Sender as External Sender
    participant Route53 as Route 53
    participant SES as Amazon SES
    participant S3 as S3 Bucket
    participant SNS as SNS Topic
    participant Lambda as Lambda Processor
    participant DDB as DynamoDB
    participant Webhook as Hermes Webhook (:8000)
    participant Hermes as Hermes Agent
    participant TG as Telegram

    Note over Sender, TG: Incoming Email Flow

    Sender->>Route53: DNS MX Lookup
    Route53-->>Sender: inbound-smtp.us-east-1.amazonaws.com
    Sender->>SES: SMTP DELIVER to user@hermes.example.com
    SES->>SES: Spam/Virus Scan, DKIM/SPF/DMARC Verify
    SES->>S3: PutObject (raw .eml) to s3://hermes-emails-prod/incoming/<msgid>
    SES->>SNS: Publish "EmailReceived" event
    SNS->>Lambda: Invoke (batch up to 10)
    Lambda->>S3: GetObject (fetch .eml)
    Lambda->>Lambda: Parse MIME (headers, text, html, attachments)
    Lambda->>DDB: PutItem (message_id, from, to, subject, status=RECEIVED)
    Lambda->>Webhook: POST /webhook/email (HMAC signed)
    Webhook->>Hermes: Store in ~/.hermes/emails.jsonl
    Webhook->>TG: Send Telegram notification (if configured)
    TG->>Hermes: User sees notification
    Hermes-->>Lambda: 200 OK {status: "ok"}
    Lambda->>DDB: UpdateItem (status=PROCESSED, webhook_result)
```

---

## Email Send Flow (Sequence Diagram)

```mermaid
sequenceDiagram
    participant User as Telegram User
    participant TG as Telegram Bot
    participant Hermes as Hermes Agent
    participant Tool as SES Send Tool
    participant SES as Amazon SES
    participant Recipient as External Recipient

    Note over User, Recipient: Outbound Email Flow

    User->>TG: /send_email to:bob@example.com subject:"Hi" body:"Hello!"
    TG->>Hermes: Forward command
    Hermes->>Tool: send_email(to, subject, body, html?)
    Tool->>SES: SendEmail API (Source: noreply@hermes.example.com)
    SES->>SES: DKIM Sign, SPF Check
    SES->>Recipient: SMTP DELIVER
    SES-->>Tool: MessageId
    Tool-->>Hermes: {success: true, message_id}
    Hermes->>TG: "✅ Email sent! MessageId: <...>"
    TG->>User: Confirmation
```

---

## Infrastructure Deployment (Terraform Resources)

```mermaid
flowchart LR
    subgraph TF["Terraform State"]
        TF_VAR["terraform.tfvars\nsecrets.sh (TF_VAR_*)"]
        TF_STATE["terraform.tfstate\nLocal backend"]
    end

    end

    subgraph PROVIDERS["Providers"]
        AWS["AWS Provider\nregion=us-east-1"]
    end

    subgraph MODULES["Resource Groups"]
        EC2_GRP["EC2 + IAM + SG\nmain.tf"]
        SES_GRP["SES + Route53 + S3 + SNS\nses.tf"]
        LAMBDA_GRP["Lambda + IAM + DynamoDB\nlambda.tf"]
        BOOT["Bootstrap\ntemplates/hermes-startup.sh"]
    end

    subgraph OUTPUTS["Outputs"]
        OUT_INSTANCE["instance_id, public_ip, private_ip"]
        OUT_SES["ses_domain_verification_token, ses_dkim_tokens, ses_mx_endpoint"]
        OUT_LAMBDA["email_processor_lambda_arn"]
        OUT_DDB["email_metadata_table"]
        OUT_SSM["ssm_session_command"]
    end

    TF_VAR --> TF_STATE
    TF_STATE --> AWS
    AWS --> EC2_GRP
    AWS --> SES_GRP
    AWS --> LAMBDA_GRP
    EC2_GRP --> BOOT
    EC2_GRP --> OUT_INSTANCE
    EC2_GRP --> OUT_SSM
    SES_GRP --> OUT_SES
    LAMBDA_GRP --> OUT_LAMBDA
    LAMBDA_GRP --> OUT_DDB
```

---

## Network & Security Boundaries

```mermaid
flowchart TD
    subgraph INTERNET["Internet (0.0.0.0/0)"]
        EMAIL_IN["Incoming SMTP\nPort 25/587/2587"]
        EMAIL_OUT["Outbound SES API\nHTTPS"]
        TG_API["Telegram Bot API\napi.telegram.org:443"]
        WEB_PORTS["Web Prototyping Ports\n3000,4000,5000,5173,8000,8080,8443,8888"]
    end

    subgraph VPC["Default VPC (172.31.0.0/16)"]
        subgraph PUBLIC["Public Subnets"]
            EC2_PUB["EC2 Instance\nPublic IP + Private IP"]
            IGW["Internet Gateway"]
        end
        subgraph PRIVATE["Private Subnets (if any)"]
            LAMBDA_VPC["Lambda ENIs\n(if VPC configured)"]
        end
    end

    subgraph AWS_MANAGED["AWS Managed Services (No VPC)"]
        SES_SVC["Amazon SES"]
        S3_SVC["S3"]
        SNS_SVC["SNS"]
        LAMBDA_SVC["Lambda Control Plane"]
        DDB_SVC["DynamoDB"]
        R53_SVC["Route 53"]
        IAM_SVC["IAM"]
        SSM_SVC["SSM Session Manager"]
    end

    %% Connections
    EMAIL_IN -->|MX → SES| SES_SVC
    SES_SVC -->|Receipt Rule| S3_SVC
    SES_SVC -->|Receipt Rule| SNS_SVC
    SNS_SVC -->|Invoke| LAMBDA_SVC
    LAMBDA_SVC -->|GetObject| S3_SVC
    LAMBDA_SVC -->|PutItem| DDB_SVC
    LAMBDA_SVC -->|HTTP :8000| EC2_PUB
    EC2_PUB -->|HTTPS| TG_API
    EC2_PUB -->|HTTPS| SES_SVC
    EC2_PUB -->|HTTPS| S3_SVC
    EC2_PUB -->|HTTPS| DDB_SVC
    WEB_PORTS -->|Security Group| EC2_PUB
    SSM_SVC -->|Session| EC2_PUB

    %% VPC Flow
    IGW <--> EC2_PUB
    EC2_PUB -.->|VPC Endpoints (optional)| S3_SVC
    EC2_PUB -.->|VPC Endpoints (optional)| DDB_SVC

    classDef internet fill:#FF6B6B,color:#fff
    classDef vpc fill:#4ECDC4,color:#fff
    classDef managed fill:#45B7D1,color:#fff

    class EMAIL_IN,EMAIL_OUT,TG_API,WEB_PORTS internet
    class EC2_PUB,IGW,LAMBDA_VPC vpc
    class SES_SVC,S3_SVC,SNS_SVC,LAMBDA_SVC,DDB_SVC,R53_SVC,IAM_SVC,SSM_SVC managed
```

---

## Data Flow Summary

```mermaid
flowchart LR
    subgraph INPUT["Inputs"]
        TFVARS["terraform.tfvars\n- ses_domain\n- route53_hosted_zone_name\n- email_s3_bucket_name\n- enable_email_processing"]
        SECRETS["secrets.sh\n- AWS creds\n- TF_VAR_provider_api_key\n- TF_VAR_telegram_bot_token\n- TF_VAR_telegram_allowed_users\n- TF_VAR_hermes_webhook_secret"]
    end

    subgraph DEPLOY["terraform apply"]
        PLAN["terraform plan"]
        APPLY["terraform apply"]
    end

    subgraph CREATED["Resources Created"]
        EC2_INST["EC2 Instance\n+ IAM Role + SG"]
        SES_DOMAIN["SES Domain Identity\n+ DKIM + MX + SPF + DMARC"]
        S3_BUCKET["S3 Bucket\n+ Policy + Lifecycle"]
        SNS_TOPIC["SNS Topic"]
        RECEIPT_RULE["SES Receipt Rule\n(S3 + SNS actions)"]
        LAMBDA_FN["Lambda Function\n+ IAM Role + Event Source"]
        DDB_TABLE["DynamoDB Table\n+ TTL"]
        R53_RECORDS["Route 53 Records\n(MX, TXT, CNAME×3, SPF, DMARC)"]
    end

    subgraph RUNTIME["Runtime (Post-Boot)"]
        HERMES_BOOT["Cloud-init → hermes-startup.sh"]
        SKILLS_INSTALLED["Skills Installed\n- hermes-email-webhook\n- ses-send-email"]
        WEBHOOK_RUNNING["Webhook Server\n:8000/webhook/email"]
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
    class EC2_INST,SES_DOMAIN,S3_BUCKET,SNS_TOPIC,RECEIPT_RULE,LAMBDA_FN,DDB_TABLE,R53_RECORDS created
    class HERMES_BOOT,SKILLS_INSTALLED,WEBHOOK_RUNNING,TG_GATEWAY runtime
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