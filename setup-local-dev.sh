#!/bin/bash
# setup-local-dev.sh - Setup for local development and testing

set -euo pipefail

echo "🏗️  Setting up local development environment..."

# Install PowerShell on Ubuntu/Debian
if ! command -v pwsh &> /dev/null; then
    echo "Installing PowerShell..."
    
    # Download and install PowerShell
    wget -q https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt-get update
    sudo apt-get install -y powershell
    
    echo "✅ PowerShell installed"
fi

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws/
    echo "✅ AWS CLI installed"
fi

# Install required PowerShell modules
echo "Installing PowerShell modules..."
pwsh -c "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module AWS.Tools.SecretsManager,AWS.Tools.S3 -Force -AllowClobber"

echo "✅ Local development environment ready!"
echo
echo "You can now run:"
echo "  pwsh ./backup_script.ps1"
echo "  pwsh ./restore-github-repos.ps1"