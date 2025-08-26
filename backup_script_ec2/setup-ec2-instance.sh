#!/bin/bash
set -euo pipefail

# Configuration
INSTANCE_TYPE="t3.small"
KEY_NAME="MY-EC2-KEY-PAIR"  # Change this to your key pair name
SECURITY_GROUP_NAME="MY-EC2-SG"  # Change this if needed
IAM_ROLE_NAME="GitHubBackupEC2Role"
IAM_POLICY_NAME="GitHubBackupEC2Policy"
S3_BUCKET_NAME="MY-S3-BUCKET"  # Change this
SECRET_NAME="MY-AWS-SECRET"
AWS_REGION="MY-REGION"  # Change this

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log_info() {
    echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[0;32m✅ [SUCCESS]\033[0m $1"
}

log_gotrek() {
    echo -e "\033[0;35m⚔️  [GOTREK]\033[0m $1"
}

log_gotrek "Forging EC2 instance for GitHub backup operations!"

# Create IAM role for EC2
create_iam_role() {
    log_info "Creating IAM role for EC2 instance..."
    
    # Trust policy for EC2
    cat > /tmp/ec2-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # Clean up existing role if it exists
    if aws iam get-role --role-name $IAM_ROLE_NAME &> /dev/null; then
        log_info "Cleaning up existing IAM role..."
        aws iam remove-role-from-instance-profile --instance-profile-name $IAM_ROLE_NAME --role-name $IAM_ROLE_NAME 2>/dev/null || true
        aws iam delete-instance-profile --instance-profile-name $IAM_ROLE_NAME 2>/dev/null || true
        aws iam detach-role-policy --role-name $IAM_ROLE_NAME --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}" 2>/dev/null || true
        aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}" 2>/dev/null || true
        aws iam delete-role --role-name $IAM_ROLE_NAME 2>/dev/null || true
        sleep 5
    fi

    # Create role
    aws iam create-role \
        --role-name $IAM_ROLE_NAME \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
        --description "IAM role for GitHub backup EC2 instance"

    # Create policy
    cat > /tmp/ec2-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:${SECRET_NAME}-*"
    },
    {
      "Sid": "S3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${S3_BUCKET_NAME}"
    },
    {
      "Sid": "S3ObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::${S3_BUCKET_NAME}/*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/github-backup/*"
    }
  ]
}
EOF

    POLICY_ARN=$(aws iam create-policy \
        --policy-name $IAM_POLICY_NAME \
        --policy-document file:///tmp/ec2-policy.json \
        --description "Policy for GitHub backup EC2 instance" \
        --query 'Policy.Arn' \
        --output text)

    aws iam attach-role-policy \
        --role-name $IAM_ROLE_NAME \
        --policy-arn $POLICY_ARN

    # Create instance profile
    aws iam create-instance-profile --instance-profile-name $IAM_ROLE_NAME
    aws iam add-role-to-instance-profile --instance-profile-name $IAM_ROLE_NAME --role-name $IAM_ROLE_NAME

    log_success "IAM role and instance profile created!"
}

# Create security group
create_security_group() {
    # Get default VPC
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
    
    # Check if security group exists
    EXISTING_SG=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region $AWS_REGION 2>/dev/null || echo "None")
    
    if [ "$EXISTING_SG" != "None" ]; then
        SECURITY_GROUP_ID=$EXISTING_SG
        log_info "Using existing security group: $SECURITY_GROUP_ID"
    else
        log_info "Creating security group..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name $SECURITY_GROUP_NAME \
            --description "Security group for GitHub backup EC2 instance" \
            --vpc-id $VPC_ID \
            --region $AWS_REGION \
            --query 'GroupId' \
            --output text)
        
        # Add SSH access (optional - for management)
        aws ec2 authorize-security-group-ingress \
            --group-id $SECURITY_GROUP_ID \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION 2>/dev/null || true
        
        log_success "Security group created: $SECURITY_GROUP_ID"
    fi
}

# Launch EC2 instance
launch_instance() {
    log_info "Launching EC2 instance..."
    
    # Get latest Amazon Linux 2 AMI
    AMI_ID=$(aws ec2 describe-images \
        --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-*" "Name=architecture,Values=x86_64" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region $AWS_REGION)
    
    # User data script to setup PowerShell
    cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
yum update -y

# Install PowerShell
curl -L https://github.com/PowerShell/PowerShell/releases/download/v7.4.0/powershell-7.4.0-linux-x64.tar.gz -o /tmp/powershell.tar.gz
mkdir -p /opt/microsoft/powershell/7
tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
chmod +x /opt/microsoft/powershell/7/pwsh
ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh

# Install AWS PowerShell modules
pwsh -c "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module AWS.Tools.SecretsManager,AWS.Tools.S3 -Force"

# Create backup directory
mkdir -p /opt/github-backup
chown ec2-user:ec2-user /opt/github-backup

# Setup CloudWatch agent (optional)
yum install -y amazon-cloudwatch-agent

echo "EC2 instance setup complete!" > /tmp/setup-complete.log
EOF

    # Launch instance
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id $AMI_ID \
        --count 1 \
        --instance-type $INSTANCE_TYPE \
        --key-name $KEY_NAME \
        --security-group-ids $SECURITY_GROUP_ID \
        --iam-instance-profile Name=$IAM_ROLE_NAME \
        --user-data file:///tmp/user-data.sh \
        --region $AWS_REGION \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=github-backup-instance},{Key=Project,Value=github-backup}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    log_success "EC2 instance launched: $INSTANCE_ID"
    
    # Wait for instance to be running
    log_info "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $AWS_REGION
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE_ID \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region $AWS_REGION)
    
    log_success "Instance running at: $PUBLIC_IP"
    
    echo
    log_info "📋 Instance Details:"
    echo "   Instance ID: $INSTANCE_ID"
    echo "   Public IP: $PUBLIC_IP"
    echo "   SSH Command: ssh -i ~/.ssh/$KEY_NAME.pem ec2-user@$PUBLIC_IP"
    echo
    log_info "🚀 To deploy backup script:"
    echo "   scp -i ~/.ssh/$KEY_NAME.pem backup_script_ec2.ps1 ec2-user@$PUBLIC_IP:/opt/github-backup/"
    echo "   ssh -i ~/.ssh/$KEY_NAME.pem ec2-user@$PUBLIC_IP 'pwsh /opt/github-backup/backup_script_ec2.ps1'"
}

# Main function
main() {
    log_gotrek "Forging EC2 instance for GitHub backup operations!"
    
    if [ "$S3_BUCKET_NAME" = "your-backup-bucket-name" ]; then
        log_error "🚨 CHANGE THE S3_BUCKET_NAME VARIABLE!"
        exit 1
    fi
    
    create_iam_role
    create_security_group
    
    # Wait for IAM role to propagate
    log_info "Waiting for IAM role to propagate..."
    sleep 30
    
    launch_instance
    
    echo
    log_gotrek "🎉 EC2 GitHub backup instance is ready for battle!"
    echo
    log_info "Next steps:"
    echo "1. Wait 2-3 minutes for instance setup to complete"
    echo "2. Upload your backup script to the instance"
    echo "3. Run the backup script"
    echo "4. Setup cron job for scheduled backups"
}

# Cleanup
cleanup() {
    rm -f /tmp/*.json /tmp/*.sh
}
trap cleanup EXIT

main "$@"