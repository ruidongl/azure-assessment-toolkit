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
    [Alias('Subscription','s')]
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

$subs = @(az account list -o json 2>$null | ConvertFrom-Json)
$ctx  = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx -and $subs.Count -eq 0) {
    Write-Host "Not signed in. Run: az login --use-device-code" -ForegroundColor Red
    exit 1
}

# If -SubscriptionId was not passed, check if the user set a subscription in
# Az PowerShell (Set-AzContext / Select-AzSubscription) or let them confirm
# when multiple subscriptions exist.
if (-not $SubscriptionId) {
    $azPsSubId = $null
    if (Get-Command Get-AzContext -ErrorAction SilentlyContinue) {
        try {
            $azPsCtx = Get-AzContext -ErrorAction SilentlyContinue
            if ($azPsCtx -and $azPsCtx.Subscription -and $azPsCtx.Subscription.Id) {
                $azPsSubId = [string]$azPsCtx.Subscription.Id
            }
        } catch {}
    }

    if ($azPsSubId -and (-not $ctx -or $ctx.id -ne $azPsSubId)) {
        Write-Host "Detected subscription from Az PowerShell context: $($azPsCtx.Subscription.Name) ($azPsSubId)" -ForegroundColor Yellow
        $SubscriptionId = $azPsSubId
    } elseif ($subs.Count -gt 1 -and [Environment]::UserInteractive) {
        $defaultSub = if ($ctx) { $ctx } else { $subs[0] }
        Write-Host "Available subscriptions:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $subs.Count; $i++) {
            $marker = if ($subs[$i].id -eq $defaultSub.id) { '*' } else { ' ' }
            Write-Host ("  [{0}] {1} {2} ({3})" -f ($i + 1), $marker, $subs[$i].name, $subs[$i].id)
        }
        $choice = Read-Host "`nSelect subscription [1-$($subs.Count), ID, or name] (Enter for '$($defaultSub.name)')"
        if ($choice -and $choice.Trim()) {
            $trimmed = $choice.Trim()
            $idx = 0
            if ([int]::TryParse($trimmed, [ref]$idx) -and $idx -ge 1 -and $idx -le $subs.Count) {
                $SubscriptionId = $subs[$idx - 1].id
            } else {
                $SubscriptionId = $trimmed
            }
        } else {
            $SubscriptionId = $defaultSub.id
        }
        Write-Host ""
    } elseif ($ctx) {
        $SubscriptionId = $ctx.id
    }
}

if ($SubscriptionId) {
    # Clear any stale AZURE_SUBSCRIPTION_ID env var that would override az account set.
    $env:AZURE_SUBSCRIPTION_ID = $null
    az account set --subscription "$SubscriptionId" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to set subscription '$SubscriptionId'. Available subscriptions:" -ForegroundColor Red
        $subs | ForEach-Object { Write-Host "  $($_.name) ($($_.id))" -ForegroundColor Yellow }
        exit 1
    }
    $ctx = az account show --subscription "$SubscriptionId" -o json 2>$null | ConvertFrom-Json
}

if (-not $ctx) {
    Write-Host "Unable to resolve active Azure subscription." -ForegroundColor Red
    exit 1
}

$SubscriptionId = [string]$ctx.id
$env:AZURE_SUBSCRIPTION_ID = $SubscriptionId

Write-Host "Subscription : $($ctx.name)" -ForegroundColor Green
Write-Host "ID           : $($ctx.id)"
Write-Host "Tenant       : $($ctx.tenantId)"
Write-Host "User         : $($ctx.user.name)`n"

& "$PSScriptRoot\Invoke-DataCollection.ps1" -SubscriptionId $SubscriptionId -OutDir $OutDir

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