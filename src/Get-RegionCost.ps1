<#
.SYNOPSIS
    Reports Azure cost for a given region over a lookback window.
.DESCRIPTION
    Queries the Cost Management API grouped by ResourceLocation and ServiceName.
    Prints every billing location before filtering, because billing labels are
    inconsistent across services ("West US", "westus", "US West").
.PARAMETER Region
    Display or CLI name of the region, e.g. "West US" or "westus".
.PARAMETER Days
    Lookback window in days. Default 30.
.PARAMETER ShowAll
    Also print every location x service row.
.EXAMPLE
    .\Get-RegionCost.ps1 -Region "West US"
.EXAMPLE
    .\Get-RegionCost.ps1 -Region "East US 2" -Days 60 -ShowAll
.NOTES
    Requires 'Cost Management Reader' or 'Billing Reader'. 'Reader' is not enough.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Region = 'West US',
    [int]$Days = 30,
    [switch]$ShowAll
)

# Must stay 'Continue'. az writes benign warnings to stderr.
$ErrorActionPreference = 'Continue'

if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv 2>$null
}
if (-not $SubscriptionId) {
    Write-Host "Not signed in. Run: az login --use-device-code" -ForegroundColor Red
    exit 1
}

$from = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-ddT00:00:00Z')
$to   = (Get-Date).ToString('yyyy-MM-ddT23:59:59Z')

$payload = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{ from = $from; to = $to }
    dataset    = @{
        granularity = 'None'
        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
        grouping    = @(
            @{ type = 'Dimension'; name = 'ResourceLocation' }
            @{ type = 'Dimension'; name = 'ServiceName' }
        )
    }
} | ConvertTo-Json -Depth 10 -Compress

$tmp = Join-Path $env:TEMP 'cm-region-query.json'
$payload | Set-Content -Path $tmp -Encoding utf8

$uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
$raw = az rest --method post --uri $uri --body "@$tmp" -o json 2>&1
$exit = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ($exit -ne 0) {
    Write-Host "Cost Management query failed." -ForegroundColor Red
    Write-Host $raw -ForegroundColor DarkYellow
    Write-Host "`nRequires 'Cost Management Reader' or 'Billing Reader'." -ForegroundColor Yellow
    exit 1
}

$parsed = $raw | ConvertFrom-Json
$cols   = $parsed.properties.columns.name
$iCost  = [array]::IndexOf($cols, 'Cost')
$iLoc   = [array]::IndexOf($cols, 'ResourceLocation')
$iSvc   = [array]::IndexOf($cols, 'ServiceName')
$iCur   = [array]::IndexOf($cols, 'Currency')

$rows = @()
foreach ($r in $parsed.properties.rows) {
    $rows += [pscustomobject]@{
        Cost     = [double]$r[$iCost]
        Location = [string]$r[$iLoc]
        Service  = [string]$r[$iSvc]
        Currency = if ($iCur -ge 0) { [string]$r[$iCur] } else { 'USD' }
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No cost data returned for the period." -ForegroundColor Yellow
    exit 0
}

$currency = ($rows | Select-Object -First 1).Currency

Write-Host "`n=== All locations, last $Days days ===" -ForegroundColor Cyan
$rows | Group-Object Location | ForEach-Object {
    [pscustomobject]@{
        Location = $(if ($_.Name) { $_.Name } else { '(unassigned)' })
        Cost     = [math]::Round((($_.Group | Measure-Object Cost -Sum).Sum), 2)
    }
} | Sort-Object Cost -Descending | Format-Table -AutoSize

# Billing labels vary: "West US", "westus", "US West", "WestUS2".
$normalized = ($Region -replace '[\s_-]', '').ToLower()
$pattern    = '^(us)?' + [regex]::Escape($normalized) + '[0-9]*$'

$match = $rows | Where-Object {
    (($_.Location -replace '[\s_-]', '').ToLower()) -match $pattern
}

$total = ($match | Measure-Object Cost -Sum).Sum
if (-not $total) { $total = 0 }

Write-Host "=== $Region ===" -ForegroundColor Cyan
Write-Host ("Period     : {0:yyyy-MM-dd} to {1:yyyy-MM-dd}" -f (Get-Date).AddDays(-$Days), (Get-Date))
Write-Host ("Matched    : {0}" -f (($match | Select-Object -ExpandProperty Location -Unique) -join ', '))
Write-Host ("TOTAL      : {0:N2} {1}" -f $total, $currency) -ForegroundColor Green
Write-Host ("Annualized : {0:N2} {1}" -f ($total / $Days * 365), $currency)

if ($match.Count -gt 0) {
    Write-Host "`n--- By service ---" -ForegroundColor Cyan
    $match | Group-Object Service | ForEach-Object {
        $c = ($_.Group | Measure-Object Cost -Sum).Sum
        [pscustomobject]@{
            Service = $_.Name
            Cost    = [math]::Round($c, 2)
            Share   = [math]::Round(($c / $total) * 100, 1)
        }
    } | Sort-Object Cost -Descending | Format-Table -AutoSize
} else {
    Write-Host "`nNo spend found matching '$Region'." -ForegroundColor Yellow
    Write-Host "Check the location list above for the exact label." -ForegroundColor Yellow
}

if ($ShowAll) {
    Write-Host "`n--- Every location x service row ---" -ForegroundColor Cyan
    $rows | Sort-Object Cost -Descending | Format-Table -AutoSize
}

Write-Host "`nNote: global services (Entra ID, Traffic Manager, DNS) bill to" -ForegroundColor DarkGray
Write-Host "'Global' or an empty location. Region totals undercount." -ForegroundColor DarkGray