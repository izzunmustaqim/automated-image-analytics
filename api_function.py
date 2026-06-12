import json
import logging
import os
from decimal import Decimal
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "ImageAnalysisMetadata")
BUCKET_NAME = os.environ.get("S3_BUCKET_NAME", "my-cs-ai-source-images")
table = dynamodb.Table(TABLE_NAME)

class DecimalEncoder(json.JSONEncoder):
    """Helper class to convert DynamoDB Decimal objects to standard numbers for JSON."""
    def default(self, obj):
        if isinstance(obj, Decimal):
            if obj % 1 > 0:
                return float(obj)
            else:
                return int(obj)
        return super(DecimalEncoder, self).default(obj)

def create_response(status_code, body):
    """Helper to format API Gateway responses with CORS headers."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*", # Allow all domains for dev
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Allow-Methods": "OPTIONS,POST,GET"
        },
        "body": json.dumps(body, cls=DecimalEncoder)
    }

def get_images():
    """Scan DynamoDB to return all analyzed images."""
    try:
        # For production, use Query with an index instead of Scan.
        # Scan is fine for a small portfolio project.
        response = table.scan()
        items = response.get("Items", [])
        
        # Sort by upload timestamp (newest first)
        items.sort(key=lambda x: x.get("UploadTimestamp", ""), reverse=True)
        
        # Generate short-lived presigned URLs for the frontend to display thumbnails securely
        for item in items:
            key = item.get("S3Key")
            if key:
                presigned_url = s3_client.generate_presigned_url(
                    'get_object',
                    Params={'Bucket': BUCKET_NAME, 'Key': key},
                    ExpiresIn=3600 # 1 hour
                )
                item["ImageUrl"] = presigned_url
                
        return create_response(200, {"items": items})
    except ClientError as e:
        logger.error(f"DynamoDB Scan Error: {str(e)}")
        return create_response(500, {"error": "Failed to retrieve images."})

def get_upload_url(filename):
    """Generate a presigned PUT URL so the browser can upload directly to S3."""
    if not filename:
        return create_response(400, {"error": "Filename is required."})
        
    try:
        presigned_url = s3_client.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': BUCKET_NAME,
                'Key': filename,
                'ContentType': 'image/jpeg' if filename.lower().endswith(('.jpg', '.jpeg')) else 'image/png'
            },
            ExpiresIn=300, # 5 minutes to upload
            HttpMethod="PUT"
        )
        return create_response(200, {"uploadUrl": presigned_url, "filename": filename})
    except ClientError as e:
        logger.error(f"S3 Presigned URL Error: {str(e)}")
        return create_response(500, {"error": "Failed to generate upload URL."})

def lambda_handler(event, context):
    """Main routing handler for API Gateway."""
    logger.info(f"Received API event: {json.dumps(event)}")
    
    http_method = event.get("httpMethod")
    path = event.get("path")
    
    # Simple routing
    if http_method == "GET" and path == "/images":
        return get_images()
        
    elif http_method == "POST" and path == "/upload-url":
        try:
            body = json.loads(event.get("body", "{}"))
            filename = body.get("filename")
            return get_upload_url(filename)
        except json.JSONDecodeError:
            return create_response(400, {"error": "Invalid JSON body."})
            
    else:
        return create_response(404, {"error": "Route not found."})
