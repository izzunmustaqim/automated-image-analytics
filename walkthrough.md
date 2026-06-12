# Walkthrough — Automated Image Analytics Pipeline

## Files Created

All files are in [Automated Image Analytics](file:///c:/Source%20Code/Automated%20Image%20Analytics):

| File | Purpose |
|---|---|
| [lambda_function.py](file:///c:/Source%20Code/Automated%20Image%20Analytics/lambda_function.py) | Lambda handler — S3 event → Rekognition → DynamoDB |
| [main.tf](file:///c:/Source%20Code/Automated%20Image%20Analytics/main.tf) | Terraform IaC — all 15 AWS resources |
| [README.md](file:///c:/Source%20Code/Automated%20Image%20Analytics/README.md) | Architecture docs + step-by-step setup guide |
| [.gitignore](file:///c:/Source%20Code/Automated%20Image%20Analytics/.gitignore) | Excludes state files, zips, caches |

---

## Architecture Decisions

### Lambda Function (`lambda_function.py`)
- **SDK clients** are instantiated at module level (outside the handler) so they're reused across warm Lambda invocations — reducing latency.
- **File extension validation** skips non-image files early, preventing wasted Rekognition API calls.
- **`MinConfidence=80`** is set directly in the Rekognition API call (server-side filtering), plus a client-side filter as a safety net.
- **UUID v4** is used for `ImageID` to guarantee uniqueness across concurrent uploads.
- **Robust error handling** with `try/except ClientError` blocks around each AWS API call, plus a top-level catch-all per record.

### Terraform (`main.tf`)
- **15 resources** defined: S3 bucket + public access block + encryption + versioning, DynamoDB table, IAM role + 4 policies + 4 attachments, Lambda function + permission, S3 notification, CloudWatch log group.
- **Least-privilege IAM**: four separate policies, each scoped to the minimum action and resource:
  - `s3:GetObject` → only `my-cs-ai-source-images/*`
  - `rekognition:DetectLabels` → `*` (Rekognition doesn't support resource-level ARNs)
  - `dynamodb:PutItem` → only the `ImageAnalysisMetadata` table ARN
  - `logs:*` → only the Lambda function's log group
- **`data "archive_file"`** automatically zips the Lambda code — no manual packaging needed.
- **S3 notifications** use three `lambda_function` blocks with `filter_suffix` for `.jpg`, `.jpeg`, `.png` — only image uploads trigger Lambda.
- **`force_destroy = true`** on the S3 bucket for easy cleanup during development.

### Cost Optimization
- DynamoDB uses `PAY_PER_REQUEST` (on-demand) — no provisioned capacity charges.
- CloudWatch log retention set to 14 days to minimize storage.
- S3 SSE-S3 encryption is free (no KMS key charges).

---

## Deployment Quick Reference

```bash
# 1. Navigate to project
cd "c:\Source Code\Automated Image Analytics"

# 2. Initialize Terraform
terraform init

# 3. Preview changes
terraform plan

# 4. Deploy (auto-approve)
terraform apply -auto-approve

# 5. Test — upload an image
aws s3 cp test-photo.jpg s3://my-cs-ai-source-images/test-photo.jpg

# 6. Verify — check DynamoDB
aws dynamodb scan --table-name ImageAnalysisMetadata --output json

# 7. Cleanup
terraform destroy -auto-approve
```

> [!IMPORTANT]
> S3 bucket names are **globally unique**. If `my-cs-ai-source-images` is taken, change `s3_bucket_name` in [main.tf](file:///c:/Source%20Code/Automated%20Image%20Analytics/main.tf#L42).
