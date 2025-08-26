#!/bin/bash
# quick-run.sh - Quick ECS task execution

set -euo pipefail

AWS_REGION="MY-AWS-REGION"  # e.g., us-east-1
CLUSTER_NAME="MY-CLUSTER-NAME"  # e.g., github-backup-cluster
TASK_FAMILY="MY-TASK-FAMILY"  # e.g., github-backup-task

echo "🚀 Launching GitHub backup task..."

# Auto-detect network configuration
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
PUBLIC_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" --query 'Subnets[].SubnetId' --output text --region $AWS_REGION | tr '\t' ',')
SECURITY_GROUP=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION)

echo "Using VPC: $VPC_ID"
echo "Using subnets: $PUBLIC_SUBNETS"
echo "Using security group: $SECURITY_GROUP"

# Launch task
TASK_ARN=$(aws ecs run-task \
    --cluster $CLUSTER_NAME \
    --task-definition $TASK_FAMILY \
    --launch-type FARGATE \
    --region $AWS_REGION \
    --network-configuration "awsvpcConfiguration={subnets=[$PUBLIC_SUBNETS],securityGroups=[$SECURITY_GROUP],assignPublicIp=ENABLED}" \
    --query 'tasks[0].taskArn' \
    --output text)

if [ "$TASK_ARN" != "None" ] && [ "$TASK_ARN" != "null" ]; then
    echo "✅ Task launched: $TASK_ARN"
    echo
    echo "Monitor with:"
    echo "  ./monitor-task.sh"
    echo
    echo "Or view logs at:"
    echo "  https://console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#logsV2:log-groups/log-group/%252Fecs%252Fgithub-backup"
else
    echo "❌ Failed to launch task!"
    exit 1
fi