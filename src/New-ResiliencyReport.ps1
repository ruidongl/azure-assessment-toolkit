[CmdletBinding()]
param(
    [string]$OutDir    = './temp',
    [string]$ReportDir = './reports'
)

. "$PSScriptRoot\_Common.ps1"

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$ReportPath = Join-Path $ReportDir "ResiliencyAssessmentReport_$(Get-Date -Format 'yyyyMMdd').md"

$adv    = Read-Json "$OutDir/advisor-reliability.json"
$res    = Read-Json "$OutDir/resources.json"
$vaults = Read-Json "$OutDir/recovery-vaults.json"
$sa     = Read-Json "$OutDir/storage-accounts.json"
$vms    = Read-Json "$OutDir/vms.json"
$ctx    = az account show -o json | ConvertFrom-Json

$high = @($adv | Where-Object { $_.impact -eq 'High'   }).Count
$med  = @($adv | Where-Object { $_.impact -eq 'Medium' }).Count
$low  = @($adv | Where-Object { $_.impact -eq 'Low'    }).Count

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Azure Resiliency Assessment')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("**Assessment Date:** $(Get-Date -Format 'MMMM d, yyyy')")
[void]$sb.AppendLine("**Subscription:** $($ctx.name) ($($ctx.id))")
[void]$sb.AppendLine('**Data Source:** Azure Advisor (High Availability) + resource inventory')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Executive Summary')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| Metric | Value |')
[void]$sb.AppendLine('|--------|-------|')
[void]$sb.AppendLine("| **Reliability recommendations** | **$($adv.Count)** |")
[void]$sb.AppendLine("| - High impact | $high |")
[void]$sb.AppendLine("| - Medium impact | $med |")
[void]$sb.AppendLine("| - Low impact | $low |")
[void]$sb.AppendLine("| Total resources | $($res.Count) |")
[void]$sb.AppendLine("| Virtual machines | $($vms.Count) |")
[void]$sb.AppendLine("| Storage accounts | $($sa.Count) |")
[void]$sb.AppendLine("| Recovery Services vaults | $($vaults.Count) |")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Regional Distribution')
[void]$sb.AppendLine('')
if ($res.Count -gt 0) {
    [void]$sb.AppendLine('| Region | Resources | Share |')
    [void]$sb.AppendLine('|--------|-----------|-------|')
    $res | Group-Object location | Sort-Object Count -Descending | ForEach-Object {
        $share = [math]::Round(($_.Count / $res.Count) * 100, 1)
        [void]$sb.AppendLine("| $($_.Name) | $($_.Count) | $share% |")
    }
    $regions = @($res | Group-Object location)
    if ($regions.Count -eq 1) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('**Single-region deployment.** No cross-region failover capability. Assess against your DR requirements.')
    }
} else {
    [void]$sb.AppendLine('_No resource data returned._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Storage Redundancy')
[void]$sb.AppendLine('')
if ($sa.Count -gt 0) {
    [void]$sb.AppendLine('| SKU | Accounts | Redundancy |')
    [void]$sb.AppendLine('|-----|----------|------------|')
    $skuMap = @{
        'Standard_LRS'   = 'Local only - no zone or region protection'
        'Standard_ZRS'   = 'Zone-redundant'
        'Standard_GRS'   = 'Geo-redundant'
        'Standard_RAGRS' = 'Geo-redundant, read access'
        'Standard_GZRS'  = 'Geo-zone-redundant'
        'Premium_LRS'    = 'Local only - no zone or region protection'
    }
    $sa | Group-Object { $_.sku.name } | Sort-Object Count -Descending | ForEach-Object {
        $desc = if ($skuMap.ContainsKey($_.Name)) { $skuMap[$_.Name] } else { $_.Name }
        [void]$sb.AppendLine("| $($_.Name) | $($_.Count) | $desc |")
    }
    $lrs = @($sa | Where-Object { $_.sku.name -like '*LRS' })
    if ($lrs.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("**$($lrs.Count) account(s) using LRS** - data is replicated only within a single datacenter.")
    }
} else {
    [void]$sb.AppendLine('_No storage accounts found._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Virtual Machine Availability')
[void]$sb.AppendLine('')
if ($vms.Count -gt 0) {
    $noZone = @($vms | Where-Object { -not $_.zones })
    [void]$sb.AppendLine("- Total VMs: **$($vms.Count)**")
    [void]$sb.AppendLine("- Without availability zone: **$($noZone.Count)**")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| VM | Region | Zone | Size | Power state |')
    [void]$sb.AppendLine('|----|--------|------|------|-------------|')
    foreach ($v in ($vms | Sort-Object location, name)) {
        $zone = if ($v.zones) { ($v.zones -join ',') } else { 'none' }
        [void]$sb.AppendLine("| $($v.name) | $($v.location) | $zone | $($v.hardwareProfile.vmSize) | $($v.powerState) |")
    }
} else {
    [void]$sb.AppendLine('_No virtual machines found._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Reliability Recommendations')
[void]$sb.AppendLine('')
if ($adv.Count -gt 0) {
    [void]$sb.AppendLine('| Count | Impact | Recommendation |')
    [void]$sb.AppendLine('|-------|--------|----------------|')
    $adv | Group-Object { $_.shortDescription.problem } |
        Sort-Object Count -Descending | Select-Object -First 40 | ForEach-Object {
            $impact = ($_.Group | Select-Object -First 1).impact
            [void]$sb.AppendLine("| $($_.Count) | $impact | $($_.Name) |")
        }
} else {
    [void]$sb.AppendLine('_No reliability recommendations returned._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Data Reference')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("**Query Timestamp:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$sb.ToString() | Set-Content -Path $ReportPath -Encoding utf8
Write-Host "Resiliency report -> $ReportPath" -ForegroundColor Green