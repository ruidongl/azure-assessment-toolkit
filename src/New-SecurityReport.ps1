[CmdletBinding()]
param(
    [string]$OutDir    = './temp',
    [string]$ReportDir = './reports'
)

. "$PSScriptRoot\_Common.ps1"

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$ReportPath = Join-Path $ReportDir "SecurityAssessmentReport_$(Get-Date -Format 'yyyyMMdd').md"

$adv     = Read-Json "$OutDir/advisor-security.json"
$score   = Read-Json "$OutDir/secure-score.json"
$alerts  = Read-Json "$OutDir/security-alerts.json"
$pricing = Read-Json "$OutDir/defender-pricing.json"
$res     = Read-Json "$OutDir/resources.json"
$subFile = Join-Path $OutDir 'subscription.json'
$ctx     = if (Test-Path $subFile) { Get-Content $subFile -Raw | ConvertFrom-Json } else { az account show -o json 2>$null | ConvertFrom-Json }

$ascore = $score | Where-Object { $_.name -eq 'ascScore' }
$pct = $null
if ($ascore -and $ascore.max) { $pct = [math]::Round(($ascore.current / $ascore.max) * 100, 1) }

$high   = @($adv | Where-Object { $_.impact -eq 'High'   }).Count
$med    = @($adv | Where-Object { $_.impact -eq 'Medium' }).Count
$low    = @($adv | Where-Object { $_.impact -eq 'Low'    }).Count
$active = @($alerts | Where-Object { $_.status -in 'Active','New' })

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Azure Security Assessment')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("**Assessment Date:** $(Get-Date -Format 'MMMM d, yyyy')")
[void]$sb.AppendLine("**Subscription:** $($ctx.name) ($($ctx.id))")
[void]$sb.AppendLine("**Tenant:** $($ctx.tenantId)")
[void]$sb.AppendLine('**Data Source:** Azure Advisor (Security) + Microsoft Defender for Cloud')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Executive Summary')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| Metric | Value |')
[void]$sb.AppendLine('|--------|-------|')
if ($ascore) {
    [void]$sb.AppendLine("| **Defender for Cloud Secure Score** | **$($ascore.current) / $($ascore.max) ($pct%)** |")
} else {
    [void]$sb.AppendLine('| **Defender for Cloud Secure Score** | _not available_ |')
}
[void]$sb.AppendLine("| **Total resources** | $($res.Count) |")
[void]$sb.AppendLine("| **Active security recommendations** | **$($adv.Count)** |")
[void]$sb.AppendLine("| - High impact | $high |")
[void]$sb.AppendLine("| - Medium impact | $med |")
[void]$sb.AppendLine("| - Low impact | $low |")
[void]$sb.AppendLine("| **Active security alerts** | **$($active.Count)** |")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('> **Note:** Secure score percentages are not comparable across dates. The maximum achievable score changes as Microsoft revises the scored control set. Compare points earned, not percentage.')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Defender for Cloud Plan Coverage')
[void]$sb.AppendLine('')
$plans = if ($pricing.value) { $pricing.value } else { $pricing }
if ($plans) {
    [void]$sb.AppendLine('| Plan | Tier | Sub-plan |')
    [void]$sb.AppendLine('|------|------|----------|')
    foreach ($p in ($plans | Sort-Object pricingTier, name)) {
        $flag = if ($p.pricingTier -ne 'Standard') { ' WARN' } else { '' }
        [void]$sb.AppendLine("| $($p.name) | $($p.pricingTier)$flag | $($p.subPlan) |")
    }
    $off = @($plans | Where-Object { $_.pricingTier -ne 'Standard' })
    if ($off.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("**$($off.Count) plan(s) not on Standard tier.** Findings for these workloads are not being generated.")
    }
} else {
    [void]$sb.AppendLine('_No pricing data returned._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Active Security Alerts')
[void]$sb.AppendLine('')
if ($active.Count -gt 0) {
    foreach ($sev in @('High','Medium','Low','Informational')) {
        $bucket = @($active | Where-Object { $_.severity -eq $sev })
        if ($bucket.Count -eq 0) { continue }
        [void]$sb.AppendLine("### $sev ($($bucket.Count))")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Alert | Resource | Detected |')
        [void]$sb.AppendLine('|-------|----------|----------|')
        foreach ($a in ($bucket | Sort-Object timeGeneratedUtc -Descending)) {
            [void]$sb.AppendLine("| $($a.alertDisplayName) | ``$($a.compromisedEntity)`` | $($a.timeGeneratedUtc) |")
        }
        [void]$sb.AppendLine('')
    }
} else {
    [void]$sb.AppendLine('_No active alerts._')
    [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')

[void]$sb.AppendLine('## Recommendations by Volume')
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
    [void]$sb.AppendLine('_No recommendations returned._')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('## Data Reference')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("**Query Timestamp:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$sb.ToString() | Set-Content -Path $ReportPath -Encoding utf8
Write-Host "Security report  -> $ReportPath" -ForegroundColor Green