"""
AWS Lambda Function – Automated Image Analytics Pipeline
=========================================================
Triggered by S3 ObjectCreated events on the 'my-cs-ai-source-images' bucket.
  1. Retrieves the uploaded image from S3.
  2. Sends the image to Amazon Rekognition (DetectLabels API).
  3. Filters labels with Confidence >= 80%.
  4. Writes a structured metadata record to DynamoDB.

Runtime  : Python 3.11
SDK      : boto3 (bundled in Lambda runtime)
"""

import json
import logging
import uuid
import urllib.parse
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DYNAMODB_TABLE_NAME = "ImageAnalysisMetadata"
REKOGNITION_MAX_LABELS = 50          # Max labels to request from Rekognition
CONFIDENCE_THRESHOLD = 80.0          # Minimum confidence score (%)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# AWS SDK Clients (reused across warm invocations)
# ---------------------------------------------------------------------------
s3_client = boto3.client("s3")
rekognition_client = boto3.client("rekognition")
dynamodb_resource = boto3.resource("dynamodb")
table = dynamodb_resource.Table(DYNAMODB_TABLE_NAME)


def lambda_handler(event, context):
    """
    Entry point invoked by S3 event notification.

    Parameters
    ----------
    event : dict
        S3 event payload containing bucket name and object key.
    context : LambdaContext
        Runtime information provided by AWS Lambda.

    Returns
    -------
    dict
        Status code and summary body for each processed record.
    """
    logger.info("Received event: %s", json.dumps(event, indent=2))

    results = []

    for record in event.get("Records", []):
        try:
            result = _process_record(record)
            results.append(result)
        except Exception as exc:
            logger.exception("Unhandled error processing record: %s", exc)
            results.append({
                "status": "ERROR",
                "error": str(exc),
            })

    return {
        "statusCode": 200,
        "body": json.dumps(results, default=str),
    }


def _process_record(record: dict) -> dict:
    """Process a single S3 event record end-to-end."""

    # ------------------------------------------------------------------
    # 1. Extract S3 metadata from the event
    # ------------------------------------------------------------------
    bucket_name = record["s3"]["bucket"]["name"]
    object_key = urllib.parse.unquote_plus(
        record["s3"]["object"]["key"], encoding="utf-8"
    )
    file_size = record["s3"]["object"].get("size", 0)

    logger.info(
        "Processing image — Bucket: %s | Key: %s | Size: %d bytes",
        bucket_name, object_key, file_size,
    )

    # Validate file extension
    lower_key = object_key.lower()
    if not (lower_key.endswith(".jpg")
            or lower_key.endswith(".jpeg")
            or lower_key.endswith(".png")):
        msg = f"Skipping non-image file: {object_key}"
        logger.warning(msg)
        return {"status": "SKIPPED", "key": object_key, "reason": msg}

    # ------------------------------------------------------------------
    # 2. Call Amazon Rekognition – DetectLabels
    # ------------------------------------------------------------------
    try:
        rekog_response = rekognition_client.detect_labels(
            Image={
                "S3Object": {
                    "Bucket": bucket_name,
                    "Name": object_key,
                }
            },
            MaxLabels=REKOGNITION_MAX_LABELS,
            MinConfidence=CONFIDENCE_THRESHOLD,
        )
    except ClientError as err:
        logger.error(
            "Rekognition API error for %s: %s",
            object_key, err.response["Error"]["Message"],
        )
        raise

    raw_labels = rekog_response.get("Labels", [])
    logger.info("Rekognition returned %d labels (≥ %.0f%% confidence)",
                len(raw_labels), CONFIDENCE_THRESHOLD)

    # ------------------------------------------------------------------
    # 3. Parse & filter labels
    # ------------------------------------------------------------------
    detected_labels = [
        {
            "Name": label["Name"],
            "Confidence": Decimal(str(round(label["Confidence"], 2))),
        }
        for label in raw_labels
        if label["Confidence"] >= CONFIDENCE_THRESHOLD
    ]

    # ------------------------------------------------------------------
    # 4. Build the DynamoDB item
    # ------------------------------------------------------------------
    image_id = str(uuid.uuid4())
    upload_timestamp = datetime.now(timezone.utc).isoformat()

    item = {
        "ImageID": image_id,
        "UploadTimestamp": upload_timestamp,
        "S3Bucket": bucket_name,
        "S3Key": object_key,
        "FileSizeInBytes": file_size,
        "DetectedLabels": detected_labels,
        "LabelCount": len(detected_labels),
    }

    # ------------------------------------------------------------------
    # 5. Write to DynamoDB
    # ------------------------------------------------------------------
    try:
        table.put_item(Item=item)
        logger.info(
            "Successfully wrote metadata — ImageID: %s | Labels: %d",
            image_id, len(detected_labels),
        )
    except ClientError as err:
        logger.error(
            "DynamoDB PutItem error for %s: %s",
            object_key, err.response["Error"]["Message"],
        )
        raise

    return {
        "status": "SUCCESS",
        "ImageID": image_id,
        "key": object_key,
        "labelsDetected": len(detected_labels),
    }
