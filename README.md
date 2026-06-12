# 🖼️ Automated Image Analytics Full-Stack App

> **Portfolio Project** — Event-driven, serverless full-stack web application on AWS using Python, Terraform, Vanilla JS, and AI.

---

## Architecture Overview

```
                                    ┌────────────────┐
                                    │    User UI     │
                                    │  (Web Browser) │
                                    └────────────────┘
                                        ▲        │
                              Get URL   │        │ Upload Image (PUT)
                                        ▼        ▼
┌─────────────────┐       ┌─────────────────┐  ┌──────────────┐      S3 Event      ┌──────────────────┐      Detect     ┌────────────────┐
│  API Gateway    │ ◄───► │   API Lambda    │  │  S3 Bucket   │ ─────────────────► │ Analyze Lambda   │ ──────────────► │  Amazon        │
│  (REST API)     │       │  (Python 3.11)  │  │ (Uploads)    │   ObjectCreated    │ (Python 3.11)    │                 │  Rekognition   │
└─────────────────┘       └─────────────────┘  └──────────────┘                    └──────────────────┘                 └────────────────┘
                                  ▲                                                         │
                                  │                                                         │ PutItem
                                  │   Scan / Query                                          ▼
                                  │                                                ┌────────────────┐
                                  └─────────────────────────────────────────────── │  DynamoDB      │
                                                                                   │  (Metadata)    │
                                                                                   └────────────────┘
```

### Data Flow

1. **Dashboard Load** — The user opens the frontend dashboard (hosted on an S3 static website). The JS queries the `API Gateway`.
2. **Pre-signed URL** — When a user wants to upload an image, the frontend calls the `API Lambda` to generate a secure, short-lived S3 pre-signed upload URL.
3. **Upload** — The browser uploads the `.jpg` or `.png` directly to the `my-cs-ai-source-images` S3 bucket.
4. **Trigger** — An `s3:ObjectCreated` event asynchronously invokes the `Analyze Lambda`.
5. **Analyze** — The Analyze Lambda calls Rekognition `DetectLabels`, which returns objects, scenes, and tags.
6. **Filter** — Labels with a confidence score below **80%** are discarded.
7. **Store** — A structured metadata record is written to the `ImageAnalysisMetadata` DynamoDB table.
8. **Display** — The dashboard refreshes its gallery from the API Gateway, dynamically showing the detected labels.

---

## AWS Services Used

| Service | Purpose | Free Tier Allowance |
|---|---|---|
| **S3** | Image storage & Frontend Hosting | 5 GB standard storage |
| **API Gateway** | REST API routing | 1M API calls/month |
| **Lambda** | Serverless compute (Python 3.11) | 1M requests + 400K GB-seconds/month |
| **Rekognition** | AI-powered label detection | 5,000 images/month (first 12 months) |
| **DynamoDB** | NoSQL metadata store | 25 GB + 25 WCU/RCU (always free) |
| **CloudWatch** | Lambda execution logs | 5 GB ingestion + 5 GB storage |
| **IAM** | Least-privilege access control | Always free |

> **Cost: $0/month** when staying within the limits above.

---

## DynamoDB Schema

| Attribute | Type | Description |
|---|---|---|
| `ImageID` | `String` (Hash Key) | UUID v4 — unique identifier per analysis |
| `UploadTimestamp` | `String` | ISO 8601 UTC timestamp |
| `S3Bucket` | `String` | Source bucket name |
| `S3Key` | `String` | Full object key path |
| `FileSizeInBytes` | `Number` | Image file size |
| `DetectedLabels` | `List<Map>` | Array of `{Name, Confidence}` objects (≥ 80%) |
| `LabelCount` | `Number` | Count of detected labels |

---

## Project Structure

```
Automated Image Analytics/
├── frontend/
│   ├── index.html            # Dashboard HTML
│   ├── styles.css            # Dark mode glassmorphism UI
│   └── app.js                # Frontend JS (API logic & rendering)
├── lambda_function.py        # Analyze Lambda — S3 → Rekognition → DynamoDB
├── api_function.py           # API Lambda — DynamoDB ↔ API Gateway ↔ S3 Presigned URLs
├── main.tf                   # Terraform IaC — Backend Resources
├── web_app.tf                # Terraform IaC — Web/API Resources
├── .gitignore                # Excludes state files, zips, caches
└── README.md                 # This file
```

---

## Prerequisites

| Tool | Min Version | Install Guide |
|---|---|---|
| **AWS CLI** | v2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| **Terraform** | v1.5+ | https://developer.hashicorp.com/terraform/install |
| **Python** | 3.11 | https://www.python.org/downloads/ |
| **AWS Account** | Free Tier | https://aws.amazon.com/free/ |

---

## Step-by-Step Setup Guide

### Step 1 — Configure AWS Credentials

```bash
# Configure your AWS access key, secret key, and default region
aws configure
```

When prompted:
- **AWS Access Key ID:** *(from IAM console)*
- **AWS Secret Access Key:** *(from IAM console)*
- **Default region name:** `us-east-1`
- **Default output format:** `json`

> ⚠️ **Security Tip:** Create a dedicated IAM user with `AdministratorAccess` for Terraform deployments. Never use root credentials.

---

### Step 2 — Initialize & Deploy Terraform

```bash
# Navigate to the project directory
cd "c:\Source Code\Automated Image Analytics"

# Initialize Terraform (downloads AWS provider)
terraform init

# Apply the infrastructure
terraform apply -auto-approve
```

**Expected outputs include:**
```
api_gateway_url = "https://<api-id>.execute-api.us-east-1.amazonaws.com/dev/"
frontend_url = "http://my-cs-ai-dashboard-<account-id>.s3-website-us-east-1.amazonaws.com"
```

---

### Step 3 — Connect the Frontend

1. Open `frontend/app.js` in a text editor.
2. Update the `API_URL` variable at the top with your `api_gateway_url` output from Terraform.
   ```javascript
   const API_URL = "https://<api-id>.execute-api.us-east-1.amazonaws.com/dev/";
   ```

---

### Step 4 — Deploy the Frontend Dashboard

Sync the local `frontend` directory to your new S3 Website bucket (replace `<account-id>` with your AWS account ID):

```bash
aws s3 sync "frontend" s3://my-cs-ai-dashboard-<account-id>/
```

---

### Step 5 — Enjoy the App!

1. Click on the `frontend_url` link generated by Terraform.
2. Drag and drop a `.jpg` or `.png` into the website.
3. Watch the progress bar as the browser uploads directly to S3.
4. Wait 2-3 seconds, and see the AWS Rekognition labels seamlessly populate your dashboard gallery!

---

### Step 6 — Clean Up (Destroy Resources)

```bash
# Remove all AWS resources to avoid any charges
terraform destroy -auto-approve
```

*(Note: You will have to empty your S3 buckets manually using `aws s3 rm s3://bucket-name --recursive` if `force_destroy` is not active.)*

---

## Future Enhancements

- [x] Add an API Gateway endpoint to query analysis results via REST API
- [x] Build a web dashboard to visualize detected labels
- [ ] Implement Cognito Authentication for user login
- [ ] Add SNS notifications for real-time alerts on specific label detections
- [ ] Add Step Functions for multi-stage processing (e.g., thumbnail generation + moderation)

---

## License

This project is open-source and available for portfolio and educational use.
