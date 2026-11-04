[CmdletBinding()]
param(
    [string[]]$ResourceGroup,
    [string]$OutDir    = './temp',
    [string]$ReportDir = './reports'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_RGCommon.ps1"

if (-not $ResourceGroup) {
    $ResourceGroup = Read-Json "$OutDir/rg-scope.json"
}
if (-not $ResourceGroup -or $ResourceGroup.Count -eq 0) {
    Write-Host "No scope found. Run Invoke-RGDataCollection.ps1 first." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$slug       = Get-ScopeSlug $ResourceGroup
$ReportPath = Join-Path $ReportDir "SecurityAssessment_${slug}_$(Get-Date -Format 'yyyyMMdd').md"

$adv       = @(Read-Json "$OutDir/rg-advisor-security.json")
$alerts    = @(Read-Json "$OutDir/rg-security-alerts.json")
$resources = @(Read-Json "$OutDir/rg-resources.json")
$subFile   = Join-Path $OutDir 'rg-subscription.json'
$ctx       = if (Test-Path $subFile) { Get-Content $subFile -Raw | ConvertFrom-Json } else { az account show -o json 2>$null | ConvertFrom-Json }

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Azure Security Assessment - Resource Group Scope")
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

# --- Summary ----------------------------------------------------------------
$high   = @($adv | Where-Object { $_.impact -eq 'High' }).Count
$medium = @($adv | Where-Object { $_.impact -eq 'Medium' }).Count
$low    = @($adv | Where-Object { $_.impact -eq 'Low' }).Count

$activeAlerts = @($alerts | Where-Object { -not $_.status -or $_.status -in 'Active','New' })
$aHigh = @($activeAlerts | Where-Object { $_.severity -eq 'High' }).Count
$aMed  = @($activeAlerts | Where-Object { $_.severity -eq 'Medium' }).Count
$aLow  = @($activeAlerts | Where-Object { $_.severity -eq 'Low' }).Count
$aInfo = @($activeAlerts | Where-Object { $_.severity -eq 'Informational' }).Count

[void]$sb.AppendLine("## Executive Summary")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| Metric | Value |")
[void]$sb.AppendLine("|--------|-------|")
[void]$sb.AppendLine("| **Active alerts** | **$($activeAlerts.Count)** |")
[void]$sb.AppendLine("| - High severity | $aHigh |")
[void]$sb.AppendLine("| - Medium severity | $aMed |")
[void]$sb.AppendLine("| - Low severity | $aLow |")
[void]$sb.AppendLine("| - Informational | $aInfo |")
[void]$sb.AppendLine("| **Recommendations** | **$($adv.Count)** |")
[void]$sb.AppendLine("| - High impact | $high |")
[void]$sb.AppendLine("| - Medium impact | $medium |")
[void]$sb.AppendLine("| - Low impact | $low |")
[void]$sb.AppendLine("| Resources in scope | $($resources.Count) |")
[void]$sb.AppendLine()

[void]$sb.AppendLine("> **Secure score is not included.** Microsoft Defender for Cloud")
[void]$sb.AppendLine("> calculates secure score at subscription scope only. There is no")
[void]$sb.AppendLine("> per-resource-group equivalent. Use the subscription-wide report for")
[void]$sb.AppendLine("> score tracking.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Alerts -----------------------------------------------------------------
[void]$sb.AppendLine("## Active Security Alerts")
[void]$sb.AppendLine()
if ($activeAlerts.Count -gt 0) {
    [void]$sb.AppendLine("| Severity | Alert | Affected Resource | Detected |")
    [void]$sb.AppendLine("|----------|-------|-------------------|----------|")
    $order = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; 'Informational' = 3 }
    $activeAlerts | Sort-Object { if ($order.ContainsKey([string]$_.severity)) { $order[[string]$_.severity] } else { 9 } } |
    ForEach-Object {
        $res  = if ($_.compromisedEntity) { [string]$_.compromisedEntity } else { Split-Path ([string]$_.id) -Leaf }
        $when = ''
        if ($_.timeGeneratedUtc) {
            try { $when = ([datetime]$_.timeGeneratedUtc).ToString('yyyy-MM-dd') } catch { $when = '' }
        }
        [void]$sb.AppendLine("| $($_.severity) | $($_.alertDisplayName) | ``$res`` | $when |")
    }
} else {
    [void]$sb.AppendLine("_No active alerts for resources in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Recommendations --------------------------------------------------------
[void]$sb.AppendLine("## Recommendations by Resource Count")
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
    [void]$sb.AppendLine("_No security recommendations returned for resources in scope._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

# --- Affected resources -----------------------------------------------------
[void]$sb.AppendLine("## Affected Resources")
[void]$sb.AppendLine()
if ($adv.Count -gt 0) {
    [void]$sb.AppendLine("| Resource | Resource Group | Findings |")
    [void]$sb.AppendLine("|----------|----------------|----------|")
    $adv | Group-Object { $_.resourceMetadata.resourceId } |
        Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object {
            $name = Split-Path $_.Name -Leaf
            $rg   = Get-RgFromResourceId $_.Name
            [void]$sb.AppendLine("| ``$name`` | ``$rg`` | $($_.Count) |")
        }
} else {
    [void]$sb.AppendLine("_No data._")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine()

[void]$sb.AppendLine("## Notes")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- Recommendation counts are per-resource. One misconfiguration applied")
[void]$sb.AppendLine("  across ten resources appears as ten findings.")
[void]$sb.AppendLine("- Advisor has no server-side resource group filter. Findings were")
[void]$sb.AppendLine("  retrieved subscription-wide and filtered by resource ID, so anything")
[void]$sb.AppendLine("  Advisor reports without a resource ID is excluded.")
[void]$sb.AppendLine("- Subscription-level controls (policy assignments, Defender plan")
[void]$sb.AppendLine("  coverage, tenant settings) are out of scope here but still affect")
[void]$sb.AppendLine("  these resources.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Query Timestamp:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

$sb.ToString() | Set-Content -Path $ReportPath -Encoding utf8
Write-Host "Security report   -> $ReportPath" -ForegroundColor Green