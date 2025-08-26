#!/bin/bash
set -euo pipefail

echo "🏗️  Starting GitHub Backup ECS Task..."
echo "Timestamp: $(date)"
echo "AWS Region: ${AWS_DEFAULT_REGION:-ap-southeast-2}"
echo "PowerShell Version: $(pwsh --version)"

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ ERROR: No AWS credentials available"
    exit 1
fi

echo "✅ AWS credentials verified"

# Run the PowerShell script
echo "🚀 Executing GitHub backup script..."
exec pwsh -File backup_script.ps1