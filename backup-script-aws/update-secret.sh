#!/bin/bash
# update-secret.sh - Update GitHub App credentials

# AWS Secrets Manager details:
# Replace with your actual secret name and region

SECRET_NAME="MY-SECRET-NAME"  # e.g., github-backup/credentials
AWS_REGION="MY-AWS-REGION"  # e.g., us-east-1

echo "=== UPDATE GITHUB APP CREDENTIALS ==="
echo

read -p "GitHub App ID: " GITHUB_APP_ID
echo
echo "GitHub App Private Key (.pem file path): "
read -p "File path: " PEM_FILE_PATH

if [ ! -f "$PEM_FILE_PATH" ]; then
    echo "❌ File not found: $PEM_FILE_PATH"
    exit 1
fi

read -p "S3 Bucket Name: " S3_BUCKET_NAME

echo
echo "Converting PEM to Base64..."
PRIVATE_KEY_BASE64=$(base64 -i "$PEM_FILE_PATH" | tr -d '\n')

echo "Updating secret..."
cat > /tmp/secret-update.json << EOF
{
  "GITHUB_APP_ID": "$GITHUB_APP_ID",
  "GITHUB_APP_PRIVATE_KEY": "$PRIVATE_KEY_BASE64",
  "S3_BUCKET_NAME": "$S3_BUCKET_NAME"
}
EOF

aws secretsmanager update-secret \
    --secret-id $SECRET_NAME \
    --secret-string file:///tmp/secret-update.json \
    --region $AWS_REGION

rm /tmp/secret-update.json

echo "✅ Secret updated successfully!"
echo "You can now run your ECS task."