#!/usr/bin/env pwsh

# Enable strict error handling
$ErrorActionPreference = "Stop"

##########################################
# Helper Functions (MUST BE FIRST!)
##########################################

function Get-GitHubBackupList {
    param(
        [Parameter(Mandatory = $true)][string]$S3Bucket,
        [Parameter(Mandatory = $true)][string]$AwsRegion
    )
    
    try {
        Write-Host "  🔍 Searching S3 bucket for backup files..." -ForegroundColor Cyan
        
        $s3Objects = Get-S3Object -BucketName $S3Bucket -Prefix "MY-S3-STORAGE/" -Region $AwsRegion
        
        if (-not $s3Objects) {
            Write-Host "  ⚠️  No objects found with prefix 'MY-S3-STORAGE/'" -ForegroundColor YelMY-S3-STORAGE  return @()
        }

        $backups = @()
        foreach ($obj in $s3Objects) {
            if ($obj.Key -match 'MY-S3-STORAGE/([^/]+)/(.+)\.zip$') {
                $timestampString = $matches[1]
                $repoName = $matches[2]
                
                try {
                    $timestampDate = [DateTime]::ParseExact($timestampString, 'yyyy-MM-dd-HHmm', $null)
                } catch {
                    $timestampDate = $obj.LastModified
                }
                
                $backups += [PSCustomObject]@{
                    Repository = $repoName
                    Timestamp = $timestampString
                    TimestampDate = $timestampDate
                    S3Key = $obj.Key
                    Size = $obj.Size
                    LastModified = $obj.LastModified
                    SizeMB = [math]::Round($obj.Size / 1MB, 2)
                }
            }
        }
        
        $backups = $backups | Sort-Object Repository | Sort-Object TimestampDate -Descending
        
        Write-Host "  ✅ Found $($backups.Count) backup files" -ForegroundColor Green
        return $backups
        
    } catch {
        Write-Host "  ❌ Failed to list S3 objects: $_" -ForegroundColor Red
        throw "Failed to retrieve backup list from S3"
    }
}

function Show-BackupSummary {
    param([Parameter(Mandatory = $true)]$Backups)
    
    Write-Host "📊 BACKUP ARCHIVE SUMMARY" -ForegroundColor White
    Write-Host "=" * 60 -ForegroundColor Gray
    
    $backupsByDate = $Backups | Group-Object Timestamp | Sort-Object Name -Descending
    
    foreach ($dateGroup in $backupsByDate) {
        $date = $dateGroup.Name
        $repos = $dateGroup.Group
        $totalSize = ($repos | Measure-Object SizeMB -Sum).Sum
        
        Write-Host "📅 Backup Date: $date ($($repos.Count) repositories, $([math]::Round($totalSize, 2)) MB total)" -ForegroundColor Cyan
        
        foreach ($repo in ($repos | Sort-Object Repository)) {
            $ageInDays = [math]::Round(((Get-Date) - $repo.LastModified).TotalDays, 1)
            Write-Host "   📦 $($repo.Repository.PadRight(30)) - $($repo.SizeMB.ToString().PadLeft(8)) MB ($ageInDays days ago)" -ForegroundColor White
        }
        Write-Host
    }
}

function Show-RestorationMenu {
    param([Parameter(Mandatory = $true)]$Backups)
    
    Write-Host "🎯 RESTORATION SELECTION MENU" -ForegroundColor White
    Write-Host "=" * 60 -ForegroundColor Gray
    
    $uniqueRepos = @{}
    foreach ($backup in $Backups) {
        if (-not $uniqueRepos.ContainsKey($backup.Repository)) {
            $uniqueRepos[$backup.Repository] = $backup
        }
    }
    
    $repoList = $uniqueRepos.Values | Sort-Object Repository
    
    Write-Host "Available repositories for restoration:" -ForegroundColor Cyan
    Write-Host
    
    for ($i = 0; $i -lt $repoList.Count; $i++) {
        $repo = $repoList[$i]
        $number = ($i + 1).ToString().PadLeft(3)
        Write-Host "$number. $($repo.Repository.PadRight(35)) - $($repo.Timestamp) ($($repo.SizeMB) MB)" -ForegroundColor White
    }
    
    Write-Host
    Write-Host "Selection Options:" -ForegroundColor Yellow
    Write-Host "  • Enter numbers (e.g., 1,3,5 or 1-5 or 1,3-7,9)" -ForegroundColor White
    Write-Host "  • Type 'all' to select all repositories" -ForegroundColor White
    Write-Host "  • Type 'quit' or 'exit' to cancel" -ForegroundColor White
    Write-Host

    while ($true) {
        $selection = Read-Host "🎯 Select repositories to restore"
        
        if ($selection -eq 'quit' -or $selection -eq 'exit') {
            return @()
        }
        
        if ($selection -eq 'all') {
            Write-Host "✅ Selected all $($repoList.Count) repositories" -ForegroundColor Green
            return $repoList
        }
        
        try {
            $selectedIndices = Parse-NumberSelection -Selection $selection -MaxNumber $repoList.Count
            $selectedRepos = @()
            foreach ($index in $selectedIndices) {
                $selectedRepos += $repoList[$index - 1]
            }
            
            Write-Host "✅ Selected $($selectedRepos.Count) repositories:" -ForegroundColor Green
            foreach ($repo in $selectedRepos) {
                Write-Host "   📦 $($repo.Repository) ($($repo.Timestamp))" -ForegroundColor White
            }
            
            $confirm = Read-Host "Confirm selection? (y/n)"
            if ($confirm -eq 'y' -or $confirm -eq 'yes') {
                return $selectedRepos
            }
            
        } catch {
            Write-Host "❌ Invalid selection: $_" -ForegroundColor Red
            Write-Host "   Please try again with valid numbers (1-$($repoList.Count))" -ForegroundColor Yellow
        }
    }
}

function Parse-NumberSelection {
    param(
        [string]$Selection,
        [int]$MaxNumber
    )
    
    $numbers = @()
    $parts = $Selection -split ','
    
    foreach ($part in $parts) {
        $part = $part.Trim()
        
        if ($part -match '^(\d+)-(\d+)$') {
            $start = [int]$matches[1]
            $end = [int]$matches[2]
            
            if ($start -lt 1 -or $end -gt $MaxNumber -or $start -gt $end) {
                throw "Invalid range $start-$end (must be 1-$MaxNumber)"
            }
            
            for ($i = $start; $i -le $end; $i++) {
                $numbers += $i
            }
        }
        elseif ($part -match '^\d+$') {
            $num = [int]$part
            if ($num -lt 1 -or $num -gt $MaxNumber) {
                throw "Invalid number $num (must be 1-$MaxNumber)"
            }
            $numbers += $num
        }
        else {
            throw "Invalid format '$part' (use numbers, ranges like 1-5, or comma-separated)"
        }
    }
    
    return ($numbers | Sort-Object | Select-Object -Unique)
}

function Get-RestoreLocation {
    Write-Host "📂 CHOOSE RESTORATION LOCATION" -ForegroundColor White
    Write-Host "=" * 40 -ForegroundColor Gray
    
    $currentDir = Get-Location
    Write-Host "Current directory: $currentDir" -ForegroundColor Cyan
    Write-Host
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  1. Current directory ($currentDir)" -ForegroundColor White
    Write-Host "  2. Create 'restored-repos' subdirectory" -ForegroundColor White
    Write-Host "  3. Specify custom path" -ForegroundColor White
    Write-Host

    $choice = Read-Host "Choose location (1-3)"
    
    switch ($choice) {
        "1" { return $currentDir.Path }
        "2" { 
            $restoreDir = Join-Path $currentDir "restored-repos"
            if (-not (Test-Path $restoreDir)) {
                New-Item -ItemType Directory -Path $restoreDir -Force | Out-Null
                Write-Host "✅ Created directory: $restoreDir" -ForegroundColor Green
            }
            return $restoreDir
        }
        "3" { 
            $customPath = Read-Host "Enter custom path"
            if (-not (Test-Path $customPath)) {
                $create = Read-Host "Directory doesn't exist. Create it? (y/n)"
                if ($create -eq 'y') {
                    New-Item -ItemType Directory -Path $customPath -Force | Out-Null
                    Write-Host "✅ Created directory: $customPath" -ForegroundColor Green
                }
            }
            return $customPath
        }
        default {
            Write-Host "❌ Invalid choice, using current directory" -ForegroundColor Yellow
            return $currentDir.Path
        }
    }
}

function Restore-SelectedRepositories {
    param(
        [Parameter(Mandatory = $true)]$SelectedRepos,
        [Parameter(Mandatory = $true)][string]$RestoreLocation,
        [Parameter(Mandatory = $true)][string]$S3Bucket,
        [Parameter(Mandatory = $true)][string]$AwsRegion
    )
    
    Write-Host "🔧 Restoring $($SelectedRepos.Count) repositories to: $RestoreLocation" -ForegroundColor Cyan
    Write-Host
    
    $successCount = 0
    $failureCount = 0
    
    foreach ($repo in $SelectedRepos) {
        try {
            Write-Host "📦 Restoring: $($repo.Repository) ($($repo.Timestamp))" -ForegroundColor White
            
            $localZip = Join-Path $env:TEMP "$($repo.Repository)-$($repo.Timestamp).zip"
            Write-Host "  📥 Downloading from S3..." -ForegroundColor Cyan
            
            Copy-S3Object -BucketName $S3Bucket -Key $repo.S3Key -LocalFile $localZip -Region $AwsRegion
            
            $extractPath = Join-Path $RestoreLocation "$($repo.Repository)-$($repo.Timestamp)"
            Write-Host "  📂 Extracting to: $extractPath" -ForegroundColor Cyan
            
            if (Test-Path $extractPath) {
                Remove-Item $extractPath -Recurse -Force
            }
            
            Expand-Archive -Path $localZip -DestinationPath $extractPath -Force
            Remove-Item $localZip -Force
            
            Write-Host "  ✅ $($repo.Repository) restored successfully" -ForegroundColor Green
            $successCount++
            
        } catch {
            Write-Host "  ❌ Failed to restore $($repo.Repository): $_" -ForegroundColor Red
            $failureCount++
        }
        
        Write-Host
    }
    
    Write-Host "📊 RESTORATION SUMMARY" -ForegroundColor White
    Write-Host "=" * 30 -ForegroundColor Gray
    Write-Host "✅ Successful restorations: $successCount" -ForegroundColor Green
    Write-Host "❌ Failed restorations: $failureCount" -ForegroundColor Red
    Write-Host "📂 Restoration location: $RestoreLocation" -ForegroundColor Cyan
}

##########################################
# Main Script
##########################################

Write-Host "=== GOTREK'S GITHUB REPOSITORY RESTORATION TOOL ===" -ForegroundColor Green
Write-Host "⚔️  'By Grimnir's beard, we'll restore your repositories from the archives!'" -ForegroundColor Purple
Write-Host "Timestamp: $(Get-Date)" -ForegroundColor Cyan
Write-Host

try {
    $secretName = $env:SECRET_NAME ?? "github-backup-config"
    $region = $env:AWS_DEFAULT_REGION ?? "ap-southeast-2"

    Write-Host "📋 Fetching configuration from AWS Secrets Manager: $secretName" -ForegroundColor Cyan
    
    try {
        $secretResponse = Get-SECSecretValue -SecretId $secretName -Region $region
        $config = $secretResponse.SecretString | ConvertFrom-Json
    } catch {
        Write-Host "❌ FATAL ERROR: Failed to retrieve secrets from AWS Secrets Manager" -ForegroundColor Red
        Write-Host "   Secret Name: $secretName" -ForegroundColor Yellow
        Write-Host "   Region: $region" -ForegroundColor Yellow
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if (-not $config.S3_BUCKET_NAME) {
        Write-Host "❌ FATAL ERROR: Missing S3_BUCKET_NAME in Secrets Manager" -ForegroundColor Red
        exit 1
    }

    $s3BucketName = $config.S3_BUCKET_NAME
    Write-Host "✅ Using S3 bucket: $s3BucketName" -ForegroundColor Green
    Write-Host

    $backups = Get-GitHubBackupList -S3Bucket $s3BucketName -AwsRegion $region
    
    if (-not $backups -or $backups.Count -eq 0) {
        Write-Host "❌ No backups found in S3 bucket: $s3BucketName" -ForegroundColor Red
        Write-Host "   Make sure you've run the backup script first!" -ForegroundColor Yellow
        exit 1
    }

    Show-BackupSummary -Backups $backups
    $selectedRepos = Show-RestorationMenu -Backups $backups

    if ($selectedRepos.Count -eq 0) {
        Write-Host "🚪 No repositories selected for restoration. Exiting gracefully." -ForegroundColor Yellow
        exit 0
    }

    $restoreLocation = Get-RestoreLocation

    Write-Host "🔧 Beginning restoration process..." -ForegroundColor Cyan
    Restore-SelectedRepositories -SelectedRepos $selectedRepos -RestoreLocation $restoreLocation -S3Bucket $s3BucketName -AwsRegion $region

    Write-Host "🎉 Repository restoration completed successfully!" -ForegroundColor Green
    Write-Host "⚔️  'Another victory for the forces of order!' - Gotrek Gurnisson" -ForegroundColor Purple

} catch {
    Write-Host "❌ RESTORATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Yellow
    exit 1
}