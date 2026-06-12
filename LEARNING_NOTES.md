# ☁️ Cloud Architecture — Learning Notes

> **Project:** Automated Image Analytics Pipeline
> **Author:** CS Graduate — Cloud Architecture Portfolio
> **Date:** June 2026
> **Stack:** Python 3.11 · AWS Lambda · S3 · Rekognition · DynamoDB · Terraform

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Why Python for Lambda?](#2-why-python-for-lambda)
3. [When to Use React vs Plain HTML](#3-when-to-use-react-vs-plain-html)
4. [Hosting — Can I Host This for Free?](#4-hosting--can-i-host-this-for-free)
5. [S3 Hosting vs CloudFront](#5-s3-hosting-vs-cloudfront)
6. [Project Structure — Monorepo vs Separate Repos](#6-project-structure--monorepo-vs-separate-repos)
7. [Complete Tech Stack Rationale](#7-complete-tech-stack-rationale)
8. [Architecture Decisions Summary](#8-architecture-decisions-summary)
9. [AWS Free Tier Cheatsheet](#9-aws-free-tier-cheatsheet)
10. [Key Concepts Learned](#10-key-concepts-learned)

---

## 1. Project Overview

**What I built:** An event-driven, serverless image analysis pipeline on AWS.

**How it works:**
1. Upload a JPG/PNG image to an S3 bucket
2. S3 fires an `ObjectCreated` event → triggers a Lambda function
3. Lambda sends the image to Amazon Rekognition's `DetectLabels` API
4. Rekognition returns detected objects, scenes, and tags with confidence scores
5. Lambda filters labels ≥ 80% confidence and writes metadata to DynamoDB

**Architecture diagram:**
```
S3 (upload) → Lambda (Python) → Rekognition (AI) → DynamoDB (storage)
                    ↓
              CloudWatch (logs)
```

**Full-stack extension:**
```
Browser → API Gateway → Lambda (API) → DynamoDB
   ↑                                       ↑
   └── S3 Static Website ──────────────────┘
                                   (reads analysis results)
```

---

## 2. Why Python for Lambda?

**Question I asked:** *"Why use Python — is it the best option for this app?"*

### Answer: Python is optimal for this specific project because:

**1. Zero dependency deployment**
- `boto3` (AWS SDK) is pre-installed in Lambda's Python runtime
- Deployment package = 1 file, ~6 KB
- Node.js/Java would require bundling dependencies (node_modules or fat JARs)

**2. Cold start performance**

| Runtime | Avg Cold Start | Package Size |
|---|---|---|
| **Python 3.11** | ~200-400ms | ~6 KB |
| Node.js 20 | ~200-400ms | ~1-5 MB |
| Java 17 | ~2-5 seconds | ~50 MB |
| Go | ~100ms | ~10 MB |

**3. Cleanest API integration code**
```python
# Python — 4 lines to call Rekognition
response = rekognition.detect_labels(
    Image={"S3Object": {"Bucket": bucket, "Name": key}},
    MaxLabels=50, MinConfidence=80
)
labels = [l["Name"] for l in response["Labels"]]
```

**4. Industry alignment**
- ~70% of Lambda functions in production use Python or Node.js
- Python dominates AI/ML — Rekognition is an AI service
- Every AWS tutorial and certification exam defaults to Python

### When I WOULDN'T use Python:

| Scenario | Better Choice |
|---|---|
| Ultra-low latency (< 10ms) | Go |
| Heavy computation (video processing) | Go or Rust |
| Full-stack app sharing frontend/backend code | Node.js |
| Enterprise team already on .NET | C# |

**Key takeaway:** Choose the language that fits the workload, not the one that's trendiest.

---

## 3. When to Use React vs Plain HTML

**Question I asked:** *"Why plain HTML? When should I use React?"*

### Decision framework:

**Use Plain HTML/CSS/JS when:**
- ≤ 1 page
- ≤ 200 lines of JavaScript
- The UI just fetches data and displays it
- No complex state management needed
- No client-side routing

**Use React when:**
- Multiple pages with client-side routing
- State changes frequently across many components
- Reusable components appear in 10+ places
- Complex forms with validation and interdependencies
- Real-time updates (WebSockets, live feeds)
- Team of multiple frontend developers

### Quick reference:

| Project Type | Use |
|---|---|
| Landing page | HTML/CSS/JS |
| Portfolio site | HTML/CSS/JS |
| Simple API dashboard | HTML/CSS/JS |
| **This image analytics app** | **HTML/CSS/JS** |
| Admin panel with CRUD | React |
| Social media app | React |
| E-commerce store | React |
| SaaS product | React |

### The interview answer:

> *"The frontend only displays API responses — there's no complex state, routing, or component reuse that would justify a framework. I chose plain JS to keep the deployment pipeline simple: 3 static files to S3, no build step. If the dashboard grew to include user auth, real-time updates, or multi-page navigation, I'd migrate to React at that point."*

**Key takeaway:** Knowing when NOT to use a framework shows stronger engineering judgement than always defaulting to React.

---

## 4. Hosting — Can I Host This for Free?

**Question I asked:** *"Can I host this app for free?"*

### Answer: Yes, 100% free under AWS Free Tier.

| Service | Free Tier Limit | My Usage | Cost |
|---|---|---|---|
| S3 | 5 GB storage | ~50 MB | $0 |
| Lambda | 1M requests/month | ~100 | $0 |
| API Gateway | 1M calls/month (12 months) | ~500 | $0 |
| Rekognition | 5,000 images/month (12 months) | ~50 | $0 |
| DynamoDB | 25 GB (always free) | < 1 MB | $0 |
| CloudWatch | 5 GB logs/month | < 10 MB | $0 |
| **Total** | | | **$0.00** |

### Watch out for:

| Risk | Prevention |
|---|---|
| Exceeding 5K Rekognition images | Set a $1 billing alarm |
| 12-month Free Tier expiring | S3, API Gateway, Rekognition start charging (pennies) |
| Forgetting to destroy dev resources | Run `terraform destroy` when done |

### Always set a billing alarm:
AWS Console → Billing → Budgets → Create a $0 budget with email alerts.

---

## 5. S3 Hosting vs CloudFront

**Question I asked:** *"S3 website hosting or CloudFront?"*

### Decision:

| | S3 Only (my choice) | S3 + CloudFront |
|---|---|---|
| URL | `http://bucket.s3-website...` | `https://d1234.cloudfront.net` |
| HTTPS | ❌ | ✅ |
| Terraform complexity | 2 resources | 8+ resources |
| Deploy speed | Instant | 5-10 min invalidation |
| Cost | $0 | $0 but more complexity |

**Why S3 only:** Portfolio/dev project — HTTP is fine. CloudFront can be added later as a "Phase 2" enhancement, which itself is a great interview talking point.

---

## 6. Project Structure — Monorepo vs Separate Repos

**Question I asked:** *"Create new directory or continue in the same project?"*

### Decision: Same directory (monorepo).

**Why:**
- **Single `terraform apply`** deploys everything
- **Shared Terraform state** — API Lambda references the same DynamoDB table and S3 bucket directly
- **One Git repo, one README** — clean portfolio link
- **Frontend files in a `frontend/` subfolder** keeps it organized

```
Automated Image Analytics/
├── lambda_function.py      # Backend — image processor
├── api_function.py         # Backend — API for dashboard
├── main.tf                 # Infrastructure — everything
├── frontend/               # Frontend — web dashboard
│   ├── index.html
│   ├── styles.css
│   └── app.js
├── README.md
└── .gitignore
```

**Key takeaway:** If resources share Terraform state, keep them in one directory.

---

## 7. Complete Tech Stack Rationale

### What I used:

| Layer | Technology | Why |
|---|---|---|
| Language | Python 3.11 | boto3 bundled, zero deps |
| Compute | AWS Lambda | Serverless, scales to zero |
| Storage | S3 | Object storage + static hosting |
| Database | DynamoDB | Always-free tier, NoSQL fits the schema |
| AI | Rekognition | Managed AI, no ML expertise needed |
| API | API Gateway | Managed REST API, 1M free calls |
| Frontend | HTML/CSS/JS | < 200 lines of JS, no framework needed |
| IaC | Terraform | Multi-cloud, widely adopted |
| Logging | CloudWatch | Native Lambda integration |

### What I didn't use (and why):

| Tech | Why Not |
|---|---|
| React/Vue/Angular | Overkill — 1 page, 3 API calls |
| Node.js | Python has boto3 bundled |
| Docker | Lambda handles packaging |
| PostgreSQL/MySQL | DynamoDB is simpler + always free |
| Express/Flask/Django | API Gateway + Lambda replaces web servers |
| npm/pip | No external dependencies |
| CloudFront | HTTP is fine for portfolio |

---

## 8. Architecture Decisions Summary

| Decision | Choice | Reasoning |
|---|---|---|
| Language | Python 3.11 | boto3 bundled, cleanest AWS integration |
| Frontend | Plain HTML/CSS/JS | < 200 lines JS, no framework overhead |
| Hosting | S3 static website | Free, no server management |
| HTTPS | Skip (S3 HTTP only) | Dev/portfolio project, add later |
| Project structure | Monorepo | Shared Terraform state, one deploy |
| DynamoDB billing | PAY_PER_REQUEST | No capacity planning, free tier eligible |
| IAM approach | 4 separate least-privilege policies | Each scoped to exact ARN |
| Log retention | 14 days | Minimize CloudWatch storage costs |
| Image ID format | UUID v4 | Globally unique across concurrent uploads |
| Confidence threshold | 80% | Filters noise, server-side + client-side |

---

## 9. AWS Free Tier Cheatsheet

### Always Free (forever)

| Service | Limit |
|---|---|
| Lambda | 1M requests + 400K GB-seconds/month |
| DynamoDB | 25 GB storage + 25 read/write capacity units |
| CloudWatch | 5 GB log ingestion/month |
| IAM | Unlimited |
| SNS | 1M publishes/month |
| SQS | 1M requests/month |

### Free for 12 Months

| Service | Limit |
|---|---|
| S3 | 5 GB standard storage |
| API Gateway | 1M REST API calls/month |
| Rekognition | 5,000 images/month |
| CloudFront | 1 TB data transfer/month |
| EC2 | 750 hours t2.micro/month |
| RDS | 750 hours db.t2.micro/month |

---

## 10. Key Concepts Learned

### Event-Driven Architecture
- S3 emits events when objects are created
- Lambda subscribes to those events and runs automatically
- No polling, no servers, no cron jobs

### Infrastructure as Code (Terraform)
- Every AWS resource defined in code, version-controlled
- `terraform plan` shows what will change before applying
- `terraform destroy` removes everything cleanly
- `data` sources read existing info; `resource` blocks create things

### IAM Least Privilege
- Each Lambda gets only the permissions it needs
- Scope to specific resource ARNs, not `*`
- Rekognition is the exception — it doesn't support resource-level ARNs
- Separate policies per service for clarity

### Serverless Architecture
- No servers to manage, patch, or scale
- Pay only for what you use (or nothing on Free Tier)
- Cold starts: first invocation is slower (~200-400ms for Python)
- Warm starts: subsequent invocations reuse the container — put SDK clients outside the handler

### DynamoDB Design
- NoSQL — no fixed schema except the hash key
- `PAY_PER_REQUEST` = on-demand pricing, no capacity planning
- `PutItem` writes a full record; `Scan` reads all records
- Good for key-value lookups, not for complex joins (use RDS for that)

---

> *"The best way to learn cloud is to build something real, break it, fix it, and explain every decision you made."*
