[CmdletBinding()]
param(
    [string]$OutDir    = './temp',
    [string]$ReportDir = './reports'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_Common.ps1"

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$ReportPath = Join-Path $ReportDir "CostOptimizationReport_$(Get-Date -Format 'yyyyMMdd').md"

$adv   = Read-Json "$OutDir/advisor-cost.json"
$perf  = Read-Json "$OutDir/advisor-performance.json"
$usage = Read-Json "$OutDir/consumption-usage.json"
$vms   = Read-Json "$OutDir/vms.json"
$disks = Read-Json "$OutDir/disks.json"
$pips  = Read-Json "$OutDir/public-ips.json"
$plans = Read-Json "$OutDir/app-service-plans.json"
$ctx   = az account show -o json 2>$null | ConvertFrom-Json

$savings  = 0.0
$currency = 'USD'
foreach ($r in $adv) {
    $v = $r.extendedProperties.annualSavingsAmount
    if ($v) { $savings += [double]$v }
    if ($r.extendedProperties.savingsCurrency) { $currency = $r.extendedProperties.savingsCurrency }
}

$high = @($adv | Where-Object { $_.impact -eq 'High'   }).Count
$med  = @($adv | Where-Object { $_.impact -eq 'Medium' }).Count
$low  = @($adv | Where-Object { $_.impact -eq 'Low'    }).Count

$total30 = 0.0
foreach ($u in $usage) {
    $c = if ($null -ne $u.pretaxCost) { $u.pretaxCost } else { $u.cost }
    if ($c) { $total30 += [double]$c }
}

$orphanDisks  = @($disks | Where-Object { $_.diskState -eq 'Unattached' })
$orphanDiskGB = ($orphanDisks | Measure-Object -Property diskSizeGb -Sum).Sum
$orphanPips   = @($pips  | Where-Object { -not $_.ipConfiguration })
$stoppedVms   = @($vms   | Where-Object { $_.powerState -and $_.powerState -ne 'VM running' })
$emptyPlans   = @($plans | Where-Object { $_.numberOfSites -eq 0 })

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Azure Cost Optimization Assessment')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("**Assessment Date:** $(Get-Date -Format 'MMMM d, yyyy')")
[void]$sb.AppendLine("**Subscription:** $($ctx.name) ($($ctx.id))")
[void]$sb.AppendLine('**Data Source:** Azure Advisor (Cost) + Consumption usage + resource inventory')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Executive Summary')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| Metric | Value |')
[void]$sb.AppendLine('|--------|-------|')
if ($usage.Count -gt 0) {
    [void]$sb.AppendLine("| **Spend, last 30 days** | **$([math]::Round($total30,2)) $currency** |")
    [void]$sb.AppendLine("| Projected annual run rate | $([math]::Round($total30 * 12.17, 2)) $currency |")
} else {
    [void]$sb.AppendLine('| **Spend, last 30 days** | _not available - requires Cost Management Reader_ |')
}
[void]$sb.AppendLine("| **Identified annual savings** | **$([math]::Round($savings,2)) $currency** |")
[void]$sb.AppendLine("| **Cost recommendations** | **$($adv.Count)** |")
[void]$sb.AppendLine("| - High impact | $high |")
[void]$sb.AppendLine("| - Medium impact | $med |")
[void]$sb.AppendLine("| - Low impact | $low |")
[void]$sb.AppendLine("| Unattached managed disks | $($orphanDisks.Count) ($orphanDiskGB GB) |")
[void]$sb.AppendLine("| Unassociated public IPs | $($orphanPips.Count) |")
[void]$sb.AppendLine("| Stopped (not deallocated) VMs | $($stoppedVms.Count) |")
[void]$sb.AppendLine("| App Service plans with no apps | $($emptyPlans.Count) |")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Cost Recommendations by Savings')
[void]$sb.AppendLine('')
if ($adv.Count -gt 0) {
    [void]$sb.AppendLine('| Annual Savings | Impact | Resource | Recommendation |')
    [void]$sb.AppendLine('|----------------|--------|----------|----------------|')
    $adv | Sort-Object { -1 * [double]($_.extendedProperties.annualSavingsAmount) } |
        Select-Object -First 40 | ForEach-Object {
            $amt  = $_.extendedProperties.annualSavingsAmount
            $disp = if ($amt) { "$([math]::Round([double]$amt,2)) $currency" } else { '-' }
            $name = ($_.resourceMetadata.resourceId -split '/')[-1]
            [void]$sb.AppendLine("| $disp | $($_.impact) | ``$name`` | $($_.shortDescription.problem) |")
        }
} else {
    [void]$sb.AppendLine('_No cost recommendations returned._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Spend by Service (last 30 days)')
[void]$sb.AppendLine('')
if ($usage.Count -gt 0) {
    [void]$sb.AppendLine('| Service | Cost | Share |')
    [void]$sb.AppendLine('|---------|------|-------|')
    $usage | Group-Object { $_.meterDetails.meterCategory } | ForEach-Object {
        $c = 0.0
        foreach ($i in $_.Group) {
            $v = if ($null -ne $i.pretaxCost) { $i.pretaxCost } else { $i.cost }
            if ($v) { $c += [double]$v }
        }
        [pscustomobject]@{ Service = $_.Name; Cost = $c }
    } | Sort-Object Cost -Descending | Select-Object -First 20 | ForEach-Object {
        $share = if ($total30 -gt 0) { [math]::Round(($_.Cost / $total30) * 100, 1) } else { 0 }
        [void]$sb.AppendLine("| $($_.Service) | $([math]::Round($_.Cost,2)) $currency | $share% |")
    }
} else {
    [void]$sb.AppendLine('_Consumption data unavailable. Requires Cost Management Reader or Billing Reader._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Idle and Orphaned Resources')
[void]$sb.AppendLine('')
if ($orphanDisks.Count -gt 0) {
    [void]$sb.AppendLine("### Unattached managed disks ($($orphanDisks.Count))")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Disk | Region | Size (GB) | SKU |')
    [void]$sb.AppendLine('|------|--------|-----------|-----|')
    foreach ($d in ($orphanDisks | Sort-Object -Property diskSizeGb -Descending)) {
        [void]$sb.AppendLine("| ``$($d.name)`` | $($d.location) | $($d.diskSizeGb) | $($d.sku.name) |")
    }
    [void]$sb.AppendLine('')
}
if ($orphanPips.Count -gt 0) {
    [void]$sb.AppendLine("### Unassociated public IP addresses ($($orphanPips.Count))")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Name | Region | SKU | Allocation |')
    [void]$sb.AppendLine('|------|--------|-----|------------|')
    foreach ($p in $orphanPips) {
        [void]$sb.AppendLine("| ``$($p.name)`` | $($p.location) | $($p.sku.name) | $($p.publicIPAllocationMethod) |")
    }
    [void]$sb.AppendLine('')
}
if ($stoppedVms.Count -gt 0) {
    [void]$sb.AppendLine("### Stopped VMs still incurring compute charges ($($stoppedVms.Count))")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('A VM in `Stopped` state still bills for compute. Only `Stopped (deallocated)` halts charges.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| VM | Region | Size | Power state |')
    [void]$sb.AppendLine('|----|--------|------|-------------|')
    foreach ($v in $stoppedVms) {
        [void]$sb.AppendLine("| ``$($v.name)`` | $($v.location) | $($v.hardwareProfile.vmSize) | $($v.powerState) |")
    }
    [void]$sb.AppendLine('')
}
if ($emptyPlans.Count -gt 0) {
    [void]$sb.AppendLine("### App Service plans hosting no apps ($($emptyPlans.Count))")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Plan | Region | SKU | Workers |')
    [void]$sb.AppendLine('|------|--------|-----|---------|')
    foreach ($p in $emptyPlans) {
        [void]$sb.AppendLine("| ``$($p.name)`` | $($p.location) | $($p.sku.name) | $($p.numberOfWorkers) |")
    }
    [void]$sb.AppendLine('')
}
if ($orphanDisks.Count -eq 0 -and $orphanPips.Count -eq 0 -and
    $stoppedVms.Count -eq 0 -and $emptyPlans.Count -eq 0) {
    [void]$sb.AppendLine('_No idle or orphaned resources detected._')
    [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Related Performance Findings')
[void]$sb.AppendLine('')
if ($perf.Count -gt 0) {
    [void]$sb.AppendLine('| Count | Impact | Recommendation |')
    [void]$sb.AppendLine('|-------|--------|----------------|')
    $perf | Group-Object { $_.shortDescription.problem } |
        Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            $impact = ($_.Group | Select-Object -First 1).impact
            [void]$sb.AppendLine("| $($_.Count) | $impact | $($_.Name) |")
        }
} else {
    [void]$sb.AppendLine('_No performance recommendations returned._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Notes')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('- Savings figures are Azure Advisor estimates based on observed utilization, not guarantees.')
[void]$sb.AppendLine('- Validate idle resources before deletion. Unattached disks may hold recoverable data.')
[void]$sb.AppendLine('- Right-sizing removes headroom for spikes. Cross-check against the resiliency report.')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("**Query Timestamp:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$sb.ToString() | Set-Content -Path $ReportPath -Encoding utf8
Write-Host "Cost report       -> $ReportPath" -ForegroundColor Green