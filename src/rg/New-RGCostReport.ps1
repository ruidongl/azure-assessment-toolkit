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
$ReportPath = Join-Path $ReportDir "CostOptimization_${slug}_$(Get-Date -Format 'yyyyMMdd').md"

$adv      = @(Read-Json "$OutDir/rg-advisor-cost.json")
$perf     = @(Read-Json "$OutDir/rg-advisor-performance.json")
$disks    = @(Read-Json "$OutDir/rg-disks.json")
$pips     = @(Read-Json "$OutDir/rg-public-ips.json")
$plans    = @(Read-Json "$OutDir/rg-app-plans.json")
$vms      = @(Read-Json "$OutDir/rg-vms.json")
$subFile  = Join-Path $OutDir 'rg-subscription.json'
$ctx      = if (Test-Path $subFile) { Get-Content $subFile -Raw | ConvertFrom-Json } else { az account show -o json 2>$null | ConvertFrom-Json }

$costRaw = $null
if (Test-Path "$OutDir/rg-cost.json") {
    try { $costRaw = Get-Content "$OutDir/rg-cost.json" -Raw | ConvertFrom-Json } catch { $costRaw = $null }
}

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Azure Cost Optimization - Resource Group Scope")
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

# --- Parse cost rows --------------------------------------------------------
$costRows = @()
$currency = 'USD'
if ($costRaw -and $costRaw.properties -and $costRaw.properties.rows) {
    $cols  = $costRaw.properties.columns.name
    $iCost = [array]::IndexOf($cols, 'Cost')
    $iRg   = [array]::IndexOf($cols, 'ResourceGroupName')
    $iSvc  = [array]::IndexOf($cols, 'ServiceName')
    $iCur  = [array]::IndexOf($cols, 'Currency')

    foreach ($r in $costRaw.properties.rows) {
        $costRows += [pscustomobject]@{
            Cost    = [double]$r[$iCost]
            Rg      = if ($iRg  -ge 0) { [string]$r[$iRg]  } else { '' }
            Service = if ($iSvc -ge 0) { [string]$r[$iSvc] } else { '' }
        }
        if ($iCur -ge 0 -and $r[$iCur]) { $currency = [string]$r[$iCur] }
    }
}
$total30 = ($costRows | Measure-Object Cost -Sum).Sum
if (-not $total30) { $total30 = 0 }

# --- Advisor savings --------------------------------------------------------
$savings = 0.0
foreach ($r in $adv) {
    $v = $r.extendedProperties.annualSavingsAmount
    $d = 0.0
    if ($v -and [double]::TryParse($v, [ref]$d)) { $savings += $d }
    if ($r.extendedProperties.savingsCurrency) { $currency = $r.extendedProperties.savingsCurrency }
}

$unattached = @($disks | Where-Object { $_.diskState -eq 'Unattached' })
$orphanPips = @($pips  | Where-Object { -not $_.ipConfiguration })
$stoppedVms = @($vms   | Where-Object { $_.powerState -eq 'VM stopped' })

$planAppCount = @{}
foreach ($p in (Read-Json "$OutDir/rg-webapps.json")) {
    if ($p.appServicePlanId) {
        $k = $p.appServicePlanId.ToLower()
        if ($planAppCount.ContainsKey($k)) { $planAppCount[$k]++ } else { $planAppCount[$k] = 1 }
    }
}
$emptyPlans = @($plans | Where-Object {
    $k = ([string]$_.id).ToLower()
    -not $planAppCount.ContainsKey($k)
})

[void]$sb.AppendLine("## Executive Summary")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| Metric | Value |")
[void]$sb.AppendLine("|--------|-------|")
if ($costRows.Count -gt 0) {
    [void]$sb.AppendLine("| **Spend, last 30 days** | **$([math]::Round($total30,2)) $currency** |")
    [void]$sb.AppendLine("| Projected annual run rate | $([math]::Round($total30 * 12.17, 2)) $currency |")
} else {
    [void]$sb.AppendLine("| **Spend, last 30 days** | _not available_ |")
}
[void]$sb.AppendLine("| **Identified annual savings** | **$([math]::Round($savings,2)) $currency** |")
[void]$sb.AppendLine("| **Cost recommendations** | **$($adv.Count)** |")
[void]$sb.AppendLine("| Unattached managed disks | $($unattached.Count) |")
[void]$sb.AppendLine("| Unassociated public IPs | $($orphanPips.Count) |")
[void]$sb.AppendLine("| Stopped (not deallocated) VMs | $($stoppedVms.Count) |")
[void]$sb.AppendLine("| App Service plans with no apps | $($emptyPlans.Count) |")
[void]$sb.AppendLine()

if ($costRows.Count -eq 0) {
    [void]$sb.AppendLine("> Spend data unavailable. The Cost Management query requires")
    [void]$sb.AppendLine("> **Cost Management Reader** or **Billing Reader**. ``Reader`` alone is")
    [void]$sb.AppendLine("> not sufficient. All other sections are unaffected.")
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Spend by resource group ------------------------------------------------
if ($costRows.Count -gt 0) {
    [void]$sb.AppendLine("## Spend by Resource Group (last 30 days)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Resource Group | Cost | Share |")
    [void]$sb.AppendLine("|----------------|------|-------|")
    $costRows | Group-Object Rg | ForEach-Object {
        $c = ($_.Group | Measure-Object Cost -Sum).Sum
        $share = if ($total30 -gt 0) { [math]::Round(($c / $total30) * 100, 1) } else { 0 }
        [pscustomobject]@{ Rg = $_.Name; Cost = $c; Share = $share }
    } | Sort-Object Cost -Descending | ForEach-Object {
        [void]$sb.AppendLine("| ``$($_.Rg)`` | $([math]::Round($_.Cost,2)) $currency | $($_.Share)% |")
    }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine("## Spend by Service (last 30 days)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Service | Cost | Share |")
    [void]$sb.AppendLine("|---------|------|-------|")
    $costRows | Group-Object Service | ForEach-Object {
        $c = ($_.Group | Measure-Object Cost -Sum).Sum
        $share = if ($total30 -gt 0) { [math]::Round(($c / $total30) * 100, 1) } else { 0 }
        [pscustomobject]@{ Svc = $_.Name; Cost = $c; Share = $share }
    } | Sort-Object Cost -Descending | Select-Object -First 20 | ForEach-Object {
        [void]$sb.AppendLine("| $($_.Svc) | $([math]::Round($_.Cost,2)) $currency | $($_.Share)% |")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine()
}

# --- Recommendations --------------------------------------------------------
[void]$sb.AppendLine("## Cost Recommendations")
[void]$sb.AppendLine()
if ($adv.Count -gt 0) {
    [void]$sb.AppendLine("| Annual Savings | Impact | Resource | Recommendation |")
    [void]$sb.AppendLine("|----------------|--------|----------|----------------|")
    $adv | Sort-Object {
        $v = $_.extendedProperties.annualSavingsAmount
        $d = 0.0
        if ($v -and [double]::TryParse($v, [ref]$d)) { -1 * $d } else { 0 }
    } | Select-Object -First 40 | ForEach-Object {
        $v = $_.extendedProperties.annualSavingsAmount
        $d = 0.0
        $amt = if ($v -and [double]::TryParse($v, [ref]$d)) {
            "$([math]::Round($d,2)) $currency"
        } else { '-' }
        $res = Split-Path ([string]$_.resourceMetadata.resourceId) -Leaf
        [void]$sb.AppendLine("| $amt | $($_.impact) | ``$res`` | $($_.shortDescription.problem) |")
    }
} else {
    [void]$sb.AppendLine("_No cost recommendations returned for resources in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Idle resources ---------------------------------------------------------
[void]$sb.AppendLine("## Idle and Orphaned Resources")
[void]$sb.AppendLine()

[void]$sb.AppendLine("### Unattached managed disks ($($unattached.Count))")
[void]$sb.AppendLine()
if ($unattached.Count -gt 0) {
    [void]$sb.AppendLine("| Disk | Region | Size (GB) | SKU |")
    [void]$sb.AppendLine("|------|--------|-----------|-----|")
    $unattached | Sort-Object { -1 * $_.diskSizeGb } | ForEach-Object {
        [void]$sb.AppendLine("| ``$($_.name)`` | $($_.location) | $($_.diskSizeGb) | $($_.sku.name) |")
    }
} else { [void]$sb.AppendLine("_None found._") }
[void]$sb.AppendLine()

[void]$sb.AppendLine("### Unassociated public IP addresses ($($orphanPips.Count))")
[void]$sb.AppendLine()
if ($orphanPips.Count -gt 0) {
    [void]$sb.AppendLine("| Name | Region | SKU | Allocation |")
    [void]$sb.AppendLine("|------|--------|-----|------------|")
    $orphanPips | Sort-Object name | ForEach-Object {
        [void]$sb.AppendLine("| ``$($_.name)`` | $($_.location) | $($_.sku.name) | $($_.publicIpAllocationMethod) |")
    }
} else { [void]$sb.AppendLine("_None found._") }
[void]$sb.AppendLine()

[void]$sb.AppendLine("### Stopped VMs still incurring compute charges ($($stoppedVms.Count))")
[void]$sb.AppendLine()
if ($stoppedVms.Count -gt 0) {
    [void]$sb.AppendLine("A VM in ``Stopped`` state still bills for compute. Only")
    [void]$sb.AppendLine("``Stopped (deallocated)`` halts charges.")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| VM | Region | Size | Power State |")
    [void]$sb.AppendLine("|----|--------|------|-------------|")
    $stoppedVms | ForEach-Object {
        [void]$sb.AppendLine("| ``$($_.name)`` | $($_.location) | $($_.hardwareProfile.vmSize) | $($_.powerState) |")
    }
} else { [void]$sb.AppendLine("_None found._") }
[void]$sb.AppendLine()

[void]$sb.AppendLine("### App Service plans hosting no apps ($($emptyPlans.Count))")
[void]$sb.AppendLine()
if ($emptyPlans.Count -gt 0) {
    [void]$sb.AppendLine("| Plan | Region | SKU | Workers |")
    [void]$sb.AppendLine("|------|--------|-----|---------|")
    $emptyPlans | ForEach-Object {
        [void]$sb.AppendLine("| ``$($_.name)`` | $($_.location) | $($_.sku.name) | $($_.numberOfWorkers) |")
    }
} else { [void]$sb.AppendLine("_None found._") }
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Performance ------------------------------------------------------------
[void]$sb.AppendLine("## Related Performance Findings")
[void]$sb.AppendLine()
if ($perf.Count -gt 0) {
    [void]$sb.AppendLine("| Count | Impact | Recommendation |")
    [void]$sb.AppendLine("|-------|--------|----------------|")
    $perf | Group-Object { $_.shortDescription.problem } |
        Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            $impact = ($_.Group | Select-Object -First 1).impact
            [void]$sb.AppendLine("| $($_.Count) | $impact | $($_.Name) |")
        }
} else {
    [void]$sb.AppendLine("_No performance recommendations returned for resources in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

[void]$sb.AppendLine("## Notes")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- Savings figures are Azure Advisor estimates based on observed")
[void]$sb.AppendLine("  utilization, not guarantees.")
[void]$sb.AppendLine("- **Resource-group cost excludes shared and subscription-level charges.**")
[void]$sb.AppendLine("  Bandwidth, support plans, Entra ID, and reservations amortized across")
[void]$sb.AppendLine("  the subscription do not appear here. The total will be lower than the")
[void]$sb.AppendLine("  workload's true cost.")
[void]$sb.AppendLine("- Validate idle resources before deletion. Unattached disks may hold")
[void]$sb.AppendLine("  recoverable data; unassociated IPs may be reserved for a planned")
[void]$sb.AppendLine("  cutover.")
[void]$sb.AppendLine("- Right-sizing removes headroom for spikes. Cross-check against the")
[void]$sb.AppendLine("  resiliency report before acting.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Query Timestamp:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$sb.ToString() | Set-Content -Path $ReportPath -Encoding utf8
Write-Host "Cost report       -> $ReportPath" -ForegroundColor Green