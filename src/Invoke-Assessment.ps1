<#
.SYNOPSIS
    Runs the Azure security, resiliency, and cost optimization assessment.
.EXAMPLE
    .\Invoke-Assessment.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
.EXAMPLE
    .\Invoke-Assessment.ps1 -Skip Cost
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutDir    = './temp',
    [string]$ReportDir = './reports',
    [ValidateSet('Security','Resiliency','Cost')]
    [string[]]$Skip = @()
)

# Must stay 'Continue'. The Azure CLI writes benign warnings to stderr and
# 'Stop' would turn those into terminating NativeCommandError failures.
$ErrorActionPreference = 'Continue'

Write-Host "`n=== Azure Assessment Toolkit ===" -ForegroundColor Cyan

# Verify every required script is present before doing any work.
$required = @(
    '_Common.ps1'
    'Invoke-DataCollection.ps1'
    'New-SecurityReport.ps1'
    'New-ResiliencyReport.ps1'
    'New-CostReport.ps1'
)
$missing = $required | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) }
if ($missing) {
    Write-Host "Missing required script(s):" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

$null = az version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Azure CLI not found. Install from https://aka.ms/installazurecli" -ForegroundColor Red
    exit 1
}

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) {
    Write-Host "Not signed in. Run: az login --use-device-code" -ForegroundColor Red
    exit 1
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId 2>$null
    $ctx = az account show -o json 2>$null | ConvertFrom-Json
}

Write-Host "Subscription : $($ctx.name)" -ForegroundColor Green
Write-Host "ID           : $($ctx.id)"
Write-Host "Tenant       : $($ctx.tenantId)"
Write-Host "User         : $($ctx.user.name)`n"

& "$PSScriptRoot\Invoke-DataCollection.ps1" -OutDir $OutDir

Write-Host "Generating reports..." -ForegroundColor Cyan

$pillars = @(
    @{ Name = 'Security';   Script = 'New-SecurityReport.ps1'   }
    @{ Name = 'Resiliency'; Script = 'New-ResiliencyReport.ps1' }
    @{ Name = 'Cost';       Script = 'New-CostReport.ps1'       }
)

foreach ($p in $pillars) {
    if ($Skip -contains $p.Name) {
        Write-Host "  $($p.Name) skipped by request" -ForegroundColor DarkGray
        continue
    }
    try {
        & (Join-Path $PSScriptRoot $p.Script) -OutDir $OutDir -ReportDir $ReportDir
    } catch {
        Write-Host "  $($p.Name) report FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n=== Complete ===" -ForegroundColor Cyan
Get-ChildItem $ReportDir -Filter *.md |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-15) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, Length, LastWriteTime |
    Format-Table -AutoSize