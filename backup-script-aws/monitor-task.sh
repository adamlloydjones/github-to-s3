#!/bin/bash
# monitor-task.sh - Real-time ECS task monitoring

AWS_REGION="MY-AWS-REGION"  # e.g., us-east-1
CLUSTER_NAME="MY-CLUSTER-NAME"  # e.g., github-backup-cluster

log_info() {
    echo -e "\033[0;34m[$(date '+%H:%M:%S')]\033[0m $1"
}

log_success() {
    echo -e "\033[0;32m[$(date '+%H:%M:%S')]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[$(date '+%H:%M:%S')]\033[0m $1"
}

while true; do
    clear
    echo "=== GOTREK'S ECS TASK MONITOR ==="
    echo "Time: $(date)"
    echo "Cluster: $CLUSTER_NAME"
    echo

    # Running tasks
    RUNNING_TASKS=$(aws ecs list-tasks \
        --cluster $CLUSTER_NAME \
        --desired-status RUNNING \
        --region $AWS_REGION \
        --query 'taskArns' \
        --output text)

    if [ -n "$RUNNING_TASKS" ] && [ "$RUNNING_TASKS" != "None" ]; then
        log_success "✅ RUNNING TASKS:"
        for task in $RUNNING_TASKS; do
            TASK_ID=$(echo $task | cut -d'/' -f3)
            echo "   Task: $TASK_ID"
            
            aws ecs describe-tasks \
                --cluster $CLUSTER_NAME \
                --tasks $task \
                --region $AWS_REGION \
                --query 'tasks[0].{Status:lastStatus,Health:healthStatus,Started:startedAt}' \
                --output table
        done
    else
        log_info "No running tasks"
    fi

    # Recent logs
    echo
    log_info "📋 RECENT LOGS:"
    LOG_STREAM=$(aws logs describe-log-streams \
        --log-group-name "/ecs/github-backup" \
        --order-by LastEventTime \
        --descending \
        --max-items 1 \
        --region $AWS_REGION \
        --query 'logStreams[0].logStreamName' \
        --output text 2>/dev/null)
    
    if [ "$LOG_STREAM" != "None" ] && [ -n "$LOG_STREAM" ]; then
        aws logs get-log-events \
            --log-group-name "/ecs/github-backup" \
            --log-stream-name "$LOG_STREAM" \
            --start-time $(($(date +%s) * 1000 - 300000)) \
            --region $AWS_REGION \
            --query 'events[-10:].message' \
            --output text 2>/dev/null | tail -10
    else
        echo "No recent logs found"
    fi

    echo
    echo "Press Ctrl+C to exit, refreshing in 10 seconds..."
    sleep 10
done