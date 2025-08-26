#!/bin/bash
set -euo pipefail

# ==========================================
# GOTREK'S COMPLETE ECS DEPLOYMENT SCRIPT
# ==========================================

# Configuration - CHANGE THESE VALUES!
AWS_REGION="MY-AWS-REGION"  # e.g., us-east-1
CLUSTER_NAME="MY-CLUSTER-NAME"  # e.g., github-backup-cluster
TASK_FAMILY="MY-TASK-FAMILY"  # e.g., github-backup-task
IMAGE_NAME="MY-IMAGE-NAME"  # e.g., github-backup
S3_BUCKET_NAME="MY-S3-BUCKET"  # 🚨 CHANGE THIS! 🚨
SECRET_NAME="MY-SCRET-NAME"  # e.g., github-backup-secret
PROJECT_NAME="MY-GITHUB-BACKUP"  # e.g., github-backup

# Advanced Configuration
USE_EXISTING_VPC="true"
CREATE_SCHEDULE="true"
SCHEDULE_EXPRESSION="cron(0 2 * * ? *)"  # Daily at 2 AM

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPOSITORY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

log_gotrek() {
    echo -e "${PURPLE}⚔️  [GOTREK]${NC} $1"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅ [SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠️  [WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}❌ [ERROR]${NC} $1"
}

log_title() {
    echo
    echo -e "${WHITE}================================${NC}"
    echo -e "${WHITE}$1${NC}"
    echo -e "${WHITE}================================${NC}"
}

print_banner() {
    echo -e "${PURPLE}"
    cat << 'EOF'
    ⚔️  GOTREK'S COMPLETE ECS DEPLOYMENT ⚔️
    
    "By Grimnir's beard, this script will forge
     the mightiest GitHub backup fortress 
     in all the Old World!"
     
             - Gotrek Gurnisson, Slayer
EOF
    echo -e "${NC}"
}

check_prerequisites() {
    log_title "CHECKING PREREQUISITES"
    
    local missing_tools=()
    
    for tool in aws docker jq; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured!"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon not running!"
        exit 1
    fi
    
    local missing_files=()
    for file in Dockerfile backup_script.ps1 entrypoint.sh; do
        if [ ! -f "$file" ]; then
            missing_files+=($file)
        fi
    done
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        log_error "Missing required files: ${missing_files[*]}"
        exit 1
    fi
    
    log_success "All prerequisites satisfied!"
}

setup_networking() {
    log_title "NETWORK RECONNAISSANCE"
    
    log_gotrek "Scouting existing network infrastructure..."
    
    # Find default VPC
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $AWS_REGION 2>/dev/null || echo "None")
    
    if [ "$VPC_ID" = "None" ] || [ "$VPC_ID" = "null" ]; then
        VPC_ID=$(aws ec2 describe-vpcs \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region $AWS_REGION)
    fi
    
    log_success "Using VPC: $VPC_ID"
    
    # Find public subnets
    PUBLIC_SUBNETS=""
    ALL_SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].SubnetId' \
        --output text \
        --region $AWS_REGION)
    
    for subnet in $ALL_SUBNETS; do
        ROUTE_TABLES=$(aws ec2 describe-route-tables \
            --filters "Name=association.subnet-id,Values=$subnet" \
            --query 'RouteTables[].Routes[?GatewayId!=null&&starts_with(GatewayId,`igw-`)].GatewayId' \
            --output text \
            --region $AWS_REGION 2>/dev/null || echo "")
        
        if [ -z "$ROUTE_TABLES" ]; then
            MAIN_RT=$(aws ec2 describe-route-tables \
                --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
                --query 'RouteTables[0].Routes[?GatewayId!=null&&starts_with(GatewayId,`igw-`)].GatewayId' \
                --output text \
                --region $AWS_REGION 2>/dev/null || echo "")
            ROUTE_TABLES=$MAIN_RT
        fi
        
        if [ -n "$ROUTE_TABLES" ] && [ "$ROUTE_TABLES" != "None" ]; then
            PUBLIC_SUBNETS="$PUBLIC_SUBNETS $subnet"
            log_success "Found internet-connected subnet: $subnet"
        fi
    done
    
    PUBLIC_SUBNETS=$(echo $PUBLIC_SUBNETS | xargs)
    
    if [ -z "$PUBLIC_SUBNETS" ]; then
        log_error "No subnets with internet access found!"
        exit 1
    fi
    
    SUBNET_IDS=$(echo $PUBLIC_SUBNETS | tr ' ' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')
    
    create_security_group
}

create_security_group() {
    EXISTING_SG=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT_NAME}-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region $AWS_REGION 2>/dev/null || echo "None")
    
    if [ "$EXISTING_SG" != "None" ] && [ "$EXISTING_SG" != "null" ]; then
        SECURITY_GROUP_ID=$EXISTING_SG
        log_info "Using existing security group: $SECURITY_GROUP_ID"
    else
        log_info "Creating security group..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "${PROJECT_NAME}-sg" \
            --description "Security group for GitHub backup ECS tasks" \
            --vpc-id $VPC_ID \
            --region $AWS_REGION \
            --query 'GroupId' \
            --output text)
        
        aws ec2 revoke-security-group-egress \
            --group-id $SECURITY_GROUP_ID \
            --protocol all \
            --port all \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION 2>/dev/null || true
        
        aws ec2 authorize-security-group-egress \
            --group-id $SECURITY_GROUP_ID \
            --protocol tcp \
            --port 443 \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION
        
        aws ec2 authorize-security-group-egress \
            --group-id $SECURITY_GROUP_ID \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION
        
        aws ec2 authorize-security-group-egress \
            --group-id $SECURITY_GROUP_ID \
            --protocol udp \
            --port 53 \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION
        
        log_success "Security group created: $SECURITY_GROUP_ID"
    fi
}

create_s3_bucket() {
    log_title "CREATING S3 TREASURE VAULT"
    
    if aws s3 ls "s3://$S3_BUCKET_NAME" &> /dev/null; then
        log_info "S3 bucket already exists: $S3_BUCKET_NAME"
    else
        log_info "Creating S3 bucket: $S3_BUCKET_NAME"
        
        if [ "$AWS_REGION" = "us-east-1" ]; then
            aws s3 mb "s3://$S3_BUCKET_NAME"
        else
            aws s3 mb "s3://$S3_BUCKET_NAME" --region $AWS_REGION
        fi
        
        aws s3api put-bucket-versioning \
            --bucket $S3_BUCKET_NAME \
            --versioning-configuration Status=Enabled
        
        log_success "S3 bucket created with versioning"
    fi
}

create_iam_roles() {
    log_title "FORGING IAM ROLES"
    
    cat > /tmp/ecs-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    # ECS Task Execution Role
    if ! aws iam get-role --role-name ecsTaskExecutionRole &> /dev/null; then
        log_info "Creating ECS Task Execution Role..."
        aws iam create-role \
            --role-name ecsTaskExecutionRole \
            --assume-role-policy-document file:///tmp/ecs-trust-policy.json
        
        aws iam attach-role-policy \
            --role-name ecsTaskExecutionRole \
            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
        
        log_success "ECS Task Execution Role created"
    fi
    
    # GitHub Backup Task Role
    local role_name="github-backup-task-role"
    local policy_name="github-backup-task-policy"
    
    if aws iam get-role --role-name $role_name &> /dev/null; then
        log_warning "Recreating task role..."
        aws iam detach-role-policy --role-name $role_name --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" 2>/dev/null || true
        aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" 2>/dev/null || true
        aws iam delete-role --role-name $role_name 2>/dev/null || true
        sleep 5
    fi
    
    log_info "Creating GitHub Backup Task Role..."
    
    aws iam create-role \
        --role-name $role_name \
        --assume-role-policy-document file:///tmp/ecs-trust-policy.json
    
    cat > /tmp/task-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:${SECRET_NAME}-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET_NAME}",
        "arn:aws:s3:::${S3_BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF
    
    POLICY_ARN=$(aws iam create-policy \
        --policy-name $policy_name \
        --policy-document file:///tmp/task-policy.json \
        --query 'Policy.Arn' \
        --output text)
    
    aws iam attach-role-policy \
        --role-name $role_name \
        --policy-arn $POLICY_ARN
    
    log_success "Task role created!"
}

build_and_push_image() {
    log_title "FORGING CONTAINER IMAGE"
    
    if ! aws ecr describe-repositories --repository-names $IMAGE_NAME --region $AWS_REGION &> /dev/null; then
        log_info "Creating ECR repository..."
        aws ecr create-repository \
            --repository-name $IMAGE_NAME \
            --region $AWS_REGION \
            --image-scanning-configuration scanOnPush=true
    fi
    
    log_info "Building Docker image..."
    docker build -t $IMAGE_NAME:latest . --no-cache
    
    log_info "Pushing to ECR..."
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY
    docker tag $IMAGE_NAME:latest $ECR_REPOSITORY:latest
    docker push $ECR_REPOSITORY:latest
    
    log_success "Container image deployed!"
}

create_ecs_resources() {
    log_title "ASSEMBLING ECS WAR MACHINE"
    
    if aws ecs describe-clusters --clusters $CLUSTER_NAME --region $AWS_REGION &> /dev/null 2>&1; then
        log_info "ECS cluster exists: $CLUSTER_NAME"
    else
        log_info "Creating ECS cluster..."
        aws ecs create-cluster \
            --cluster-name $CLUSTER_NAME \
            --capacity-providers FARGATE \
            --region $AWS_REGION
        log_success "ECS cluster created!"
    fi
    
    if aws logs describe-log-groups --log-group-name-prefix "/ecs/github-backup" --region $AWS_REGION | grep -q "/ecs/github-backup"; then
        log_info "Log group exists"
    else
        aws logs create-log-group \
            --log-group-name "/ecs/github-backup" \
            --region $AWS_REGION
        
        aws logs put-retention-policy \
            --log-group-name "/ecs/github-backup" \
            --retention-in-days 14 \
            --region $AWS_REGION
        
        log_success "Log group created"
    fi
    
    log_info "Registering task definition..."
    
    cat > /tmp/task-definition.json << EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/github-backup-task-role",
  "containerDefinitions": [
    {
      "name": "github-backup",
      "image": "$ECR_REPOSITORY:latest",
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/github-backup",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "environment": [
        {
          "name": "AWS_DEFAULT_REGION",
          "value": "$AWS_REGION"
        },
        {
          "name": "SECRET_NAME",
          "value": "$SECRET_NAME"
        }
      ],
      "stopTimeout": 120
    }
  ]
}
EOF
    
    aws ecs register-task-definition \
        --cli-input-json file:///tmp/task-definition.json \
        --region $AWS_REGION > /dev/null
    
    log_success "Task definition registered!"
}

setup_secrets() {
    log_title "SECURING THE VAULT"
    
    if ! aws secretsmanager describe-secret --secret-id $SECRET_NAME --region $AWS_REGION &> /dev/null; then
        log_warning "Creating placeholder secret..."
        
        cat > /tmp/secret.json << EOF
{
  "GITHUB_APP_ID": "YOUR_GITHUB_APP_ID_HERE",
  "GITHUB_APP_PRIVATE_KEY": "YOUR_BASE64_ENCODED_PRIVATE_KEY_HERE",
  "S3_BUCKET_NAME": "$S3_BUCKET_NAME"
}
EOF
        
        aws secretsmanager create-secret \
            --name $SECRET_NAME \
            --description "GitHub backup configuration" \
            --secret-string file:///tmp/secret.json \
            --region $AWS_REGION
        
        log_warning "🚨 Update secret with real GitHub App credentials!"
    else
        log_info "Secret exists: $SECRET_NAME"
    fi
}

run_test_task() {
    log_title "TESTING DEPLOYMENT"
    
    log_info "Launching test task..."
    
    TASK_ARN=$(aws ecs run-task \
        --cluster $CLUSTER_NAME \
        --task-definition $TASK_FAMILY \
        --launch-type FARGATE \
        --region $AWS_REGION \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --query 'tasks[0].taskArn' \
        --output text)
    
    if [ "$TASK_ARN" != "None" ] && [ "$TASK_ARN" != "null" ]; then
        log_success "Test task launched: $TASK_ARN"
    else
        log_error "Failed to launch test task!"
    fi
}

display_summary() {
    log_title "DEPLOYMENT COMPLETE!"
    
    echo -e "${GREEN}"
    cat << 'EOF'
    ⚔️  BY GRIMNIR'S BEARD, THE FORTRESS IS COMPLETE! ⚔️
EOF
    echo -e "${NC}"
    
    echo
    log_info "🏰 Infrastructure Summary:"
    echo -e "   ${CYAN}VPC:${NC} $VPC_ID"
    echo -e "   ${CYAN}Subnets:${NC} $SUBNET_IDS"
    echo -e "   ${CYAN}Security Group:${NC} $SECURITY_GROUP_ID"
    echo -e "   ${CYAN}S3 Bucket:${NC} $S3_BUCKET_NAME"
    echo -e "   ${CYAN}ECR Repository:${NC} $ECR_REPOSITORY"
    echo -e "   ${CYAN}ECS Cluster:${NC} $CLUSTER_NAME"
    
    echo
    log_warning "🚨 BEFORE PRODUCTION USE:"
    echo -e "   ${YELLOW}1.${NC} Update GitHub App credentials in Secrets Manager"
    echo -e "   ${YELLOW}2.${NC} Ensure GitHub App is installed on repositories"
    
    echo
    log_info "📋 Manual Run Command:"
    echo "aws ecs run-task --cluster $CLUSTER_NAME --task-definition $TASK_FAMILY --launch-type FARGATE --region $AWS_REGION --network-configuration \"awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}\""
}

cleanup() {
    rm -f /tmp/*.json
}
trap cleanup EXIT

main() {
    print_banner
    
    if [ "$S3_BUCKET_NAME" = "your-github-backups" ]; then
        log_error "🚨 CHANGE THE S3_BUCKET_NAME VARIABLE!"
        exit 1
    fi
    
    log_gotrek "Beginning the greatest deployment!"
    
    check_prerequisites
    setup_networking
    create_s3_bucket
    create_iam_roles
    build_and_push_image
    create_ecs_resources
    setup_secrets
    
    log_info "Waiting for IAM propagation..."
    sleep 30
    
    display_summary
    
    echo
    read -p "Run test task now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        run_test_task
    fi
    
    log_gotrek "KHAZAD AI-MÊNU! The fortress stands ready!"
}

main "$@"