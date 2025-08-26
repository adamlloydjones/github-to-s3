FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

# Install required packages
RUN apt-get update && \
    apt-get install -y curl unzip ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws/

# Install AWS PowerShell modules
RUN pwsh -c "Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module AWS.Tools.SecretsManager,AWS.Tools.S3 -Force -AllowClobber"

# Create app directory
WORKDIR /app

# Copy PowerShell script and entrypoint
COPY backup_script.ps1 /app/
COPY entrypoint.sh /app/

# Make entrypoint executable
RUN chmod +x /app/entrypoint.sh

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]