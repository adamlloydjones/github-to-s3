#!/usr/bin/env pwsh

# Enable strict error handling
$ErrorActionPreference = "Stop"

Write-Host "=== GitHub Repository Backup to S3 (EC2 Version) ===" -ForegroundColor Green
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host "Instance ID: $(Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -TimeoutSec 5 2>/dev/null || 'Unknown')"
Write-Host "Timestamp: $(Get-Date)"

try {
    # Configuration - can be environment variables or parameters
    $secretName = $env:SECRET_NAME ?? "MY_AWS_SECRET"
    $region = $env:AWS_DEFAULT_REGION ?? (Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -TimeoutSec 5 2>/dev/null) ?? "MY-AWS-REGION"

    Write-Host "Using AWS Region: $region" -ForegroundColor Cyan
    Write-Host "Fetching configuration from AWS Secrets Manager: $secretName" -ForegroundColor Cyan
    
    try {
        # EC2 instance will use its IAM role automatically - no explicit credentials needed!
        $secretResponse = Get-SECSecretValue -SecretId $secretName -Region $region
        $config = $secretResponse.SecretString | ConvertFrom-Json
    } catch {
        Write-Host "❌ FATAL ERROR: Failed to retrieve secrets from AWS Secrets Manager" -ForegroundColor Red
        Write-Host "   Secret Name: $secretName" -ForegroundColor Yellow
        Write-Host "   Region: $region" -ForegroundColor Yellow
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Make sure the EC2 instance has an IAM role with Secrets Manager access!" -ForegroundColor Yellow
        exit 1
    }

    if (-not $config.GITHUB_APP_ID -or -not $config.S3_BUCKET_NAME -or -not $config.GITHUB_APP_PRIVATE_KEY) {
        Write-Host "❌ FATAL ERROR: Missing required configuration fields" -ForegroundColor Red
        Write-Host "   Required: GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, S3_BUCKET_NAME" -ForegroundColor Yellow
        Write-Host "   Found keys: $($config.PSObject.Properties.Name -join ', ')" -ForegroundColor Yellow
        exit 1
    }

    $githubAppId = $config.GITHUB_APP_ID
    $s3BucketName = $config.S3_BUCKET_NAME
    Write-Host "✅ Configuration loaded - App ID: $githubAppId, Bucket: $s3BucketName" -ForegroundColor Green

    # Get private key
    try {
        $privateKey = Get-PrivateKey -PrivateKeyValue $config.GITHUB_APP_PRIVATE_KEY
    } catch {
        Write-Host "❌ FATAL ERROR: Failed to process private key" -ForegroundColor Red
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Generate JWT
    Write-Host "Generating GitHub App JWT token..." -ForegroundColor Cyan
    try {
        $jwtToken = Get-GitHubAppJWT -AppId $githubAppId -PrivateKey $privateKey
        Write-Host "✅ JWT token generated successfully" -ForegroundColor Green
    } catch {
        Write-Host "❌ FATAL ERROR: Failed to generate JWT token" -ForegroundColor Red
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Get installation token
    try {
        $installationToken = Get-GitHubInstallationToken -JwtToken $jwtToken
    } catch {
        Write-Host "❌ FATAL ERROR: Failed to get installation token" -ForegroundColor Red
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Backup repositories
    Write-Host "Starting repository backup process..." -ForegroundColor Cyan
    try {
        Backup-GitHubReposToS3 -AccessToken $installationToken -S3Bucket $s3BucketName -AwsRegion $region
        Write-Host "=== Repository backup completed successfully! ===" -ForegroundColor Green
        
        # Optional: Send SNS notification on success
        if ($config.SNS_SUCCESS_TOPIC) {
            Send-SNSMessage -TopicArn $config.SNS_SUCCESS_TOPIC -Message "GitHub backup completed successfully at $(Get-Date)" -Region $region
        }
        
        exit 0
    } catch {
        Write-Host "❌ FATAL ERROR: Repository backup failed" -ForegroundColor Red
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        
        # Optional: Send SNS notification on failure
        if ($config.SNS_ERROR_TOPIC) {
            Send-SNSMessage -TopicArn $config.SNS_ERROR_TOPIC -Message "GitHub backup FAILED: $($_.Exception.Message)" -Region $region
        }
        
        exit 1
    }

} catch {
    Write-Host "❌ UNEXPECTED ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Yellow
    exit 1
}

##########################################
# Helper Functions
##########################################

function Get-PrivateKey {
    param([string]$PrivateKeyValue)
    
    if (-not $PrivateKeyValue) {
        throw "No private key found in Secrets Manager"
    }
    
    Write-Host "  Loading private key from Secrets Manager..." -ForegroundColor Cyan
    
    # Check if Base64 encoded
    if ($PrivateKeyValue -match '^[A-Za-z0-9+/=]+$' -and $PrivateKeyValue.Length -gt 500) {
        try {
            $privateKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PrivateKeyValue))
            Write-Host "  ✅ Private key decoded from Base64" -ForegroundColor Green
            return $privateKey
        } catch {
            Write-Host "  Base64 decode failed, treating as plain text" -ForegroundColor Yellow
        }
    }
    
    $privateKey = $PrivateKeyValue -replace "\\n", "`n"
    Write-Host "  ✅ Private key loaded from Secrets Manager" -ForegroundColor Green
    return $privateKey
}

function Import-RsaPrivateKey {
    param([Parameter(Mandatory = $true)][string]$PemString)
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.ImportFromPem($PemString)
        return $rsa
    } catch {
        throw "Failed to import RSA private key: $_"
    }
}

function Convert-ToBase64Url {
    param([byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes) -replace '\+', '-' -replace '/', '_' -replace '=', '')
}

function Get-GitHubAppJWT {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$PrivateKey
    )
    try {
        $header = @{ alg = "RS256"; typ = "JWT" } | ConvertTo-Json -Compress
        $iat = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $exp = $iat + 600
        $payload = @{ iat = $iat; exp = $exp; iss = $AppId } | ConvertTo-Json -Compress

        $rsa = Import-RsaPrivateKey -PemString $PrivateKey

        $headerBase64 = Convert-ToBase64Url ([Text.Encoding]::UTF8.GetBytes($header))
        $payloadBase64 = Convert-ToBase64Url ([Text.Encoding]::UTF8.GetBytes($payload))

        $hashAlg = [System.Security.Cryptography.HashAlgorithmName]::SHA256
        $padding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        $signatureBytes = $rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes("$headerBase64.$payloadBase64"),
            $hashAlg,
            $padding
        )

        $signature = Convert-ToBase64Url $signatureBytes
        return "$headerBase64.$payloadBase64.$signature"
    } catch {
        throw "Error generating GitHub App JWT Token: $_"
    }
}

function Get-GitHubInstallationToken {
    param([Parameter(Mandatory = $true)][string]$JwtToken)
    
    $headers = @{
        Authorization = "Bearer $JwtToken"
        Accept = "application/vnd.github+json"
        "User-Agent" = "PowerShellGitHubBackup-EC2/1.0"
    }

    try {
        Write-Host "  Fetching GitHub App installations..." -ForegroundColor Cyan
        $installations = Invoke-RestMethod -Uri "https://api.github.com/app/installations" -Headers $headers -Method GET
        
        if (-not $installations -or $installations.Count -eq 0) {
            throw "No installations found for GitHub App"
        }

        $installationId = $installations[0].id
        Write-Host "✅ Using installation ID: $installationId (Account: $($installations[0].account.login))" -ForegroundColor Green

        Write-Host "  Requesting installation access token..." -ForegroundColor Cyan
        $tokenUrl = "https://api.github.com/app/installations/$installationId/access_tokens"
        $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Headers $headers -Method POST
        
        if (-not $tokenResponse -or -not $tokenResponse.token) {
            throw "Failed to retrieve installation access token"
        }

        $token = [string]$tokenResponse.token
        Write-Host "✅ Installation token retrieved (expires: $($tokenResponse.expires_at))" -ForegroundColor Green
        return $token
        
    } catch {
        throw "Failed to get installation token: $_"
    }
}

function Backup-GitHubReposToS3 {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$S3Bucket,
        [Parameter(Mandatory = $true)][string]$AwsRegion
    )
    
    $headers = @{
        Authorization = "token $AccessToken"
        Accept = "application/vnd.github+json"
        "User-Agent" = "PowerShellGitHubBackup-EC2/1.0"
    }

    try {
        Write-Host "  Fetching repositories from GitHub..." -ForegroundColor Cyan
        $reposResponse = Invoke-RestMethod -Uri "https://api.github.com/installation/repositories" -Headers $headers -Method GET
        $repositories = $reposResponse.repositories
        
        if (-not $repositories -or $repositories.Count -eq 0) {
            Write-Host "No repositories found in installation" -ForegroundColor Yellow
            return
        }

        Write-Host "Found $($repositories.Count) repositories to backup" -ForegroundColor Green
        $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
        
        # Get instance ID for backup metadata
        $instanceId = try { 
            Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -TimeoutSec 5 
        } catch { 
            "unknown" 
        }

        foreach ($repo in $repositories) {
            $repoName = $repo.name
            $fullName = $repo.full_name
            $defaultBranch = $repo.default_branch
            
            Write-Host "Processing repository: $fullName" -ForegroundColor White
            
            try {
                $zipUrl = "https://api.github.com/repos/$fullName/zipball/$defaultBranch"
                $localZip = "/tmp/$repoName-$timestamp.zip"
                
                Write-Host "  📥 Downloading from $defaultBranch branch..." -ForegroundColor Cyan
                Invoke-WebRequest -Uri $zipUrl -Headers $headers -OutFile $localZip
                
                if (-not (Test-Path $localZip)) {
                    throw "Downloaded file not found: $localZip"
                }
                
                $fileSize = (Get-Item $localZip).Length
                Write-Host "  ✅ Downloaded ($([math]::Round($fileSize/1MB, 2)) MB)" -ForegroundColor Green
                
                # Add metadata tags for S3 object
                $s3Key = "github-backups/$timestamp/$repoName.zip"
                $metadata = @{
                    'backup-timestamp' = $timestamp
                    'repository-name' = $repoName
                    'source-instance' = $instanceId
                    'branch' = $defaultBranch
                }
                
                Write-Host "  ☁️  Uploading to s3://$S3Bucket/$s3Key" -ForegroundColor Cyan
                
                # EC2 instance uses IAM role automatically - no explicit credentials needed!
                Write-S3Object -BucketName $S3Bucket -File $localZip -Key $s3Key -Region $AwsRegion -Metadata $metadata -Force
                
                Remove-Item $localZip -Force -ErrorAction SilentlyContinue
                Write-Host "  ✅ $repoName backup completed" -ForegroundColor Green
                
            } catch {
                Write-Host "  ❌ BACKUP FAILED: $fullName - Error: $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        }
        
        Write-Host "🎉 All repositories backed up to S3!" -ForegroundColor Green
    } catch {
        throw "Repository backup process failed: $_"
    }
}