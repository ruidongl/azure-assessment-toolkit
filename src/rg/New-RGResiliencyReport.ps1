[CmdletBinding()]
param(
    [string[]]$ResourceGroup,
    [string]$OutDir    = './temp',
    [string]$ReportDir = './reports'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_RGCommon.ps1"

if (-not $ResourceGroup) { $ResourceGroup = Read-Json "$OutDir/rg-scope.json" }
if (-not $ResourceGroup -or $ResourceGroup.Count -eq 0) {
    Write-Host "No scope found. Run Invoke-RGDataCollection.ps1 first." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$slug       = Get-ScopeSlug $ResourceGroup
$ReportPath = Join-Path $ReportDir "ResiliencyAssessment_${slug}_$(Get-Date -Format 'yyyyMMdd').md"

$adv       = @(Read-Json "$OutDir/rg-advisor-reliability.json")
$resources = @(Read-Json "$OutDir/rg-resources.json")
$storage   = @(Read-Json "$OutDir/rg-storage-accounts.json")
$vms       = @(Read-Json "$OutDir/rg-vms.json")
$vaults    = @(Read-Json "$OutDir/rg-recovery-vaults.json")
$subFile   = Join-Path $OutDir 'rg-subscription.json'
$ctx       = if (Test-Path $subFile) { Get-Content $subFile -Raw | ConvertFrom-Json } else { az account show -o json 2>$null | ConvertFrom-Json }

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Azure Resiliency Assessment - Resource Group Scope")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Assessment Date:** $(Get-Date -Format 'MMMM d, yyyy')")
if ($ctx -and $ctx.id) {
    [void]$sb.AppendLine("**Subscription:** $($ctx.name) ($($ctx.id))")
}
[void]$sb.AppendLine("**Scope:** $(Get-ScopeLabel $ResourceGroup)")
[void]$sb.AppendLine()
foreach ($rg in $ResourceGroup) { [void]$sb.AppendLine("- ``$rg``") }
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

$high   = @($adv | Where-Object { $_.impact -eq 'High' }).Count
$medium = @($adv | Where-Object { $_.impact -eq 'Medium' }).Count
$low    = @($adv | Where-Object { $_.impact -eq 'Low' }).Count

$lrs    = @($storage | Where-Object { $_.sku.name -like '*LRS*' }).Count
$redund = $storage.Count - $lrs

[void]$sb.AppendLine("## Executive Summary")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| Metric | Value |")
[void]$sb.AppendLine("|--------|-------|")
[void]$sb.AppendLine("| **Reliability recommendations** | **$($adv.Count)** |")
[void]$sb.AppendLine("| - High impact | $high |")
[void]$sb.AppendLine("| - Medium impact | $medium |")
[void]$sb.AppendLine("| - Low impact | $low |")
[void]$sb.AppendLine("| Resources in scope | $($resources.Count) |")
[void]$sb.AppendLine("| Virtual machines | $($vms.Count) |")
[void]$sb.AppendLine("| Storage accounts | $($storage.Count) |")
[void]$sb.AppendLine("| - Locally redundant (LRS) | $lrs |")
[void]$sb.AppendLine("| - Zone or geo redundant | $redund |")
[void]$sb.AppendLine("| Recovery Services vaults | $($vaults.Count) |")
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Regional distribution --------------------------------------------------
[void]$sb.AppendLine("## Regional Distribution")
[void]$sb.AppendLine()
if ($resources.Count -gt 0) {
    [void]$sb.AppendLine("| Region | Resources | Share |")
    [void]$sb.AppendLine("|--------|-----------|-------|")
    $resources | Group-Object location | Sort-Object Count -Descending | ForEach-Object {
        $share = [math]::Round(($_.Count / $resources.Count) * 100, 1)
        [void]$sb.AppendLine("| $($_.Name) | $($_.Count) | $share% |")
    }
} else {
    [void]$sb.AppendLine("_No resources found in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Recommendations --------------------------------------------------------
[void]$sb.AppendLine("## Top Reliability Recommendations")
[void]$sb.AppendLine()
if ($adv.Count -gt 0) {
    [void]$sb.AppendLine("| Count | Impact | Recommendation |")
    [void]$sb.AppendLine("|-------|--------|----------------|")
    $adv | Group-Object { $_.shortDescription.problem } |
        Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
            $impact = ($_.Group | Select-Object -First 1).impact
            [void]$sb.AppendLine("| $($_.Count) | $impact | $($_.Name) |")
        }
} else {
    [void]$sb.AppendLine("_No reliability recommendations returned for resources in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Storage redundancy -----------------------------------------------------
[void]$sb.AppendLine("## Storage Redundancy")
[void]$sb.AppendLine()
if ($storage.Count -gt 0) {
    [void]$sb.AppendLine("| Storage Account | Region | SKU | Resource Group |")
    [void]$sb.AppendLine("|-----------------|--------|-----|----------------|")
    $storage | Sort-Object { $_.sku.name }, name | ForEach-Object {
        $rg = if ($_.resourceGroup) { $_.resourceGroup } else { Get-RgFromResourceId $_.id }
        [void]$sb.AppendLine("| ``$($_.name)`` | $($_.location) | $($_.sku.name) | ``$rg`` |")
    }
} else {
    [void]$sb.AppendLine("_No storage accounts in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- VM availability --------------------------------------------------------
[void]$sb.AppendLine("## Virtual Machine Availability")
[void]$sb.AppendLine()
if ($vms.Count -gt 0) {
    [void]$sb.AppendLine("| VM | Region | Zone | Availability Set | Power State |")
    [void]$sb.AppendLine("|----|--------|------|------------------|-------------|")
    $vms | Sort-Object name | ForEach-Object {
        $zone = if ($_.zones -and $_.zones.Count -gt 0) { $_.zones -join ',' } else { '-' }
        $aset = if ($_.availabilitySet -and $_.availabilitySet.id) {
            Split-Path $_.availabilitySet.id -Leaf
        } else { '-' }
        $power = if ($_.powerState) { $_.powerState } else { 'unknown' }
        [void]$sb.AppendLine("| ``$($_.name)`` | $($_.location) | $zone | $aset | $power |")
    }
} else {
    [void]$sb.AppendLine("_No virtual machines in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

[void]$sb.AppendLine("## Notes")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- Findings are advisory. Validate against your own RTO and RPO targets.")
[void]$sb.AppendLine("- LRS is appropriate for reproducible data such as build artifacts or")
[void]$sb.AppendLine("  caches. The recommendation matters most for data that cannot be")
[void]$sb.AppendLine("  regenerated.")
[void]$sb.AppendLine("- **A single resource group rarely tells the whole resiliency story.**")
[void]$sb.AppendLine("  Paired DR resources, shared vaults, and replication targets commonly")
[void]$sb.AppendLine("  live in a different resource group and will not appear here. Confirm")
[void]$sb.AppendLine("  whether a DR pair exists outside this scope before concluding a")
[void]$sb.AppendLine("  workload is unprotected.")
[void]$sb.AppendLine("- Backup status is not shown per-VM. Recovery Services vaults in other")
[void]$sb.AppendLine("  resource groups may protect these machines.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Query Timestamp:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$sb.ToString() | Set-Content -Path $ReportPath -Encoding utf8
Write-Host "Resiliency report -> $ReportPath" -ForegroundColor Green