# 🛠️ Gotrek's GitHub Backup System

*"By Grimnir's beard, the finest repository backup solution ever forged!"*

A comprehensive GitHub repository backup and restoration system using AWS ECS, PowerShell, and S3.

## 🚀 Features

- **Automated GitHub App authentication** with JWT token generation
- **Scalable ECS container deployment** with Fargate
- **Secure credential management** via AWS Secrets Manager
- **Timestamped backups** to S3 with versioning
- **Interactive restoration interface** with multiple selection options
- **Complete infrastructure automation** with deployment scripts
- **Real-time monitoring** and logging via CloudWatch

## 📋 Prerequisites

- AWS CLI configured with appropriate permissions
- Docker installed and running
- GitHub App created with repository access
- S3 bucket for backup storage

## 🔧 Quick Start

1. **Clone and setup:**
   ```bash
   git clone <your-repo>
   cd github-backup
   chmod +x *.sh