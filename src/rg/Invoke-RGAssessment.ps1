<#
.SYNOPSIS
    Runs security, resiliency, and cost assessment for specific resource groups.
.PARAMETER ResourceGroup
    One or more resource group names. Prompts if omitted.
.PARAMETER Skip
    Pillars to omit: Security, Resiliency, Cost.
.EXAMPLE
    .\Invoke-RGAssessment.ps1 -ResourceGroup rg-app-prod
.EXAMPLE
    .\Invoke-RGAssessment.ps1 -ResourceGroup rg-app-prod,rg-data-prod -Skip Cost
.EXAMPLE
    .\Invoke-RGAssessment.ps1 -ListResourceGroups
#>
[CmdletBinding()]
param(
    [Alias('g','rg')]
    [string[]]$ResourceGroup,
    [Alias('Subscription','s')]
    [string]$SubscriptionId,
    [string]$OutDir,
    [string]$ReportDir,
    [ValidateSet('Security','Resiliency','Cost')]
    [string[]]$Skip = @(),
    [switch]$ListResourceGroups,
    [switch]$SkipCollection
)

$ErrorActionPreference = 'Continue'

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $OutDir)    { $OutDir    = Join-Path $root 'temp' }
if (-not $ReportDir) { $ReportDir = Join-Path $root 'reports' }

# Normalize comma-separated strings if passed as a single string (e.g. "rg1,rg2")
if ($ResourceGroup) {
    $ResourceGroup = @($ResourceGroup | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- Sign-in & subscription check -------------------------------------------
$subs = @(az account list -o json 2>$null | ConvertFrom-Json)
$ctx  = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx -and $subs.Count -eq 0) {
    Write-Host "Not signed in. Run: az login --use-device-code" -ForegroundColor Red
    exit 1
}

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
    } elseif ($subs.Count -gt 1 -and [Environment]::UserInteractive -and (-not $ResourceGroup -or $ResourceGroup.Count -eq 0)) {
        $defaultSub = if ($ctx) { $ctx } else { $subs[0] }
        Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
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
    } elseif ($ctx) {
        $SubscriptionId = $ctx.id
    }
}

if ($SubscriptionId) {
    $env:AZURE_SUBSCRIPTION_ID = $null
    az account set --subscription "$SubscriptionId" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to set subscription '$SubscriptionId'. Available subscriptions:" -ForegroundColor Red
        $subs | ForEach-Object { Write-Host "  $($_.name) ($($_.id))" -ForegroundColor Yellow }
        exit 1
    }
    $ctx = az account show --subscription "$SubscriptionId" -o json 2>$null | ConvertFrom-Json
}

if (-not $ctx -or -not $ctx.id) {
    Write-Host "Unable to resolve active Azure subscription." -ForegroundColor Red
    exit 1
}

$SubscriptionId = [string]$ctx.id
$env:AZURE_SUBSCRIPTION_ID = $SubscriptionId

Write-Host ""
Write-Host "Subscription : $($ctx.name) ($SubscriptionId)" -ForegroundColor Cyan
Write-Host "Tenant       : $($ctx.tenantId)" -ForegroundColor DarkGray

# --- List mode --------------------------------------------------------------
if ($ListResourceGroups) {
    Write-Host "`nAccessible resource groups:`n" -ForegroundColor Cyan
    cmd /c "az group list --subscription `"$SubscriptionId`" --query `"[].{Name:name,Location:location}`" -o table < nul 2>nul"
    exit 0
}

# --- Prompt if not supplied -------------------------------------------------
if (-not $ResourceGroup -or $ResourceGroup.Count -eq 0) {
    $accessibleRgs = @(cmd /c "az group list --subscription `"$SubscriptionId`" --query `"[].name`" -o tsv < nul 2>nul" | Where-Object { $_ } | Sort-Object)
    if ($accessibleRgs.Count -gt 0) {
        Write-Host "`nAccessible resource groups in $($ctx.name):`n" -ForegroundColor Cyan
        for ($i = 0; $i -lt $accessibleRgs.Count; $i++) {
            Write-Host ("  [{0,2}] {1}" -f ($i + 1), $accessibleRgs[$i]) -ForegroundColor Gray
        }
        Write-Host ""
        $entry = Read-Host "Enter resource group name(s) or numbers (comma-separated, or 'all')"
    } else {
        Write-Host "`nEnter the resource group name(s) you have access to:`n" -ForegroundColor Cyan
        $entry = Read-Host "Resource group name(s), comma-separated"
    }

    if (-not $entry -or -not $entry.Trim()) {
        Write-Host "No resource group supplied." -ForegroundColor Red
        exit 1
    }
    if ($entry.Trim() -ieq 'all' -and $accessibleRgs.Count -gt 0) {
        $ResourceGroup = $accessibleRgs
    } else {
        $selected = @()
        foreach ($part in ($entry -split ',')) {
            $t = $part.Trim()
            if (-not $t) { continue }
            $idx = 0
            if ($accessibleRgs.Count -gt 0 -and [int]::TryParse($t, [ref]$idx) -and $idx -ge 1 -and $idx -le $accessibleRgs.Count) {
                $selected += $accessibleRgs[$idx - 1]
            } else {
                $selected += $t
            }
        }
        $ResourceGroup = $selected
    }
}

Write-Host "Scope        : $($ResourceGroup -join ', ')" -ForegroundColor Cyan
Write-Host ""

# --- Preflight --------------------------------------------------------------
$required = @(
    'Invoke-RGDataCollection.ps1'
    'New-RGSecurityReport.ps1'
    'New-RGResiliencyReport.ps1'
    'New-RGCostReport.ps1'
)
$missing = $required | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) }
if ($missing) {
    Write-Host "Missing script(s):" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    exit 1
}

# --- Collect ----------------------------------------------------------------
if (-not $SkipCollection) {
    & (Join-Path $PSScriptRoot 'Invoke-RGDataCollection.ps1') `
        -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId -OutDir $OutDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
    Write-Host "Skipping collection, using existing data in $OutDir" -ForegroundColor DarkGray
}

# --- Reports ----------------------------------------------------------------
Write-Host "Generating reports..." -ForegroundColor Cyan

if ($Skip -notcontains 'Security') {
    & (Join-Path $PSScriptRoot 'New-RGSecurityReport.ps1') `
        -ResourceGroup $ResourceGroup -OutDir $OutDir -ReportDir $ReportDir
}
if ($Skip -notcontains 'Resiliency') {
    & (Join-Path $PSScriptRoot 'New-RGResiliencyReport.ps1') `
        -ResourceGroup $ResourceGroup -OutDir $OutDir -ReportDir $ReportDir
}
if ($Skip -notcontains 'Cost') {
    & (Join-Path $PSScriptRoot 'New-RGCostReport.ps1') `
        -ResourceGroup $ResourceGroup -OutDir $OutDir -ReportDir $ReportDir
}

Write-Host ""
Write-Host "Done. Reports in $ReportDir" -ForegroundColor Green
Write-Host ""