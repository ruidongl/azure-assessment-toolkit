<#
.SYNOPSIS
    Collects assessment data scoped to one or more resource groups.
.PARAMETER ResourceGroup
    One or more resource group names.
.EXAMPLE
    .\Invoke-RGDataCollection.ps1 -ResourceGroup rg-app-prod
.EXAMPLE
    .\Invoke-RGDataCollection.ps1 -ResourceGroup rg-app-prod,rg-data-prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('g','rg')]
    [string[]]$ResourceGroup,

    [Alias('Subscription','s')]
    [string]$SubscriptionId,

    [string]$OutDir = './temp'
)

# Do not change to 'Stop'. az writes warnings to stderr on several commands.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_RGCommon.ps1"

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Normalize comma-separated resource group names if passed as a single string
$ResourceGroup = @($ResourceGroup | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($SubscriptionId) {
    $env:AZURE_SUBSCRIPTION_ID = $null
    az account set --subscription "$SubscriptionId" 2>$null
    $ctx = az account show --subscription "$SubscriptionId" -o json 2>$null | ConvertFrom-Json
} else {
    $ctx = az account show -o json 2>$null | ConvertFrom-Json
}

if (-not $ctx -or -not $ctx.id) {
    Write-Host "Not signed in or subscription not found. Run: az login --use-device-code" -ForegroundColor Red
    exit 1
}

$SubscriptionId = [string]$ctx.id
$env:AZURE_SUBSCRIPTION_ID = $SubscriptionId
$ctx | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutDir 'rg-subscription.json') -Encoding utf8

# --- Validate the resource groups exist before doing any work ---------------
Write-Host "Validating scope..." -ForegroundColor Cyan
$valid = @()
foreach ($rg in $ResourceGroup) {
    $exists = cmd /c "az group exists --name `"$rg`" --subscription `"$SubscriptionId`" -o tsv < nul 2>nul"
    if ($exists -eq 'true') {
        Write-Host ("  {0,-34} OK" -f $rg) -ForegroundColor Green
        $valid += $rg
    } else {
        Write-Host ("  {0,-34} NOT FOUND / NO ACCESS" -f $rg) -ForegroundColor Red
    }
}

if ($valid.Count -eq 0) {
    Write-Host "`nNo valid resource groups. Check names with: az group list -o table" -ForegroundColor Red
    exit 1
}
$ResourceGroup = $valid

# Record the scope so report scripts know what was collected.
$ResourceGroup | ConvertTo-Json -Depth 3 |
    Set-Content -Path (Join-Path $OutDir 'rg-scope.json') -Encoding utf8

# --- Server-side scoped queries, run once per resource group ----------------
# These accept --resource-group, so filtering happens at the API.
# JMESPath projections strip tags to avoid case-insensitive duplicate key
# failures in PowerShell 5.1 ConvertFrom-Json.
$perRg = [ordered]@{
    'rg-resources'        = "az resource list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,type:type,location:location,resourceGroup:resourceGroup}`" -o json"
    'rg-vms'              = "az vm list -d -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup,zones:zones,availabilitySet:availabilitySet,hardwareProfile:{vmSize:hardwareProfile.vmSize},powerState:powerState}`" -o json"
    'rg-storage-accounts' = "az storage account list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup,sku:{name:sku.name}}`" -o json"
    'rg-recovery-vaults'  = "az backup vault list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup}`" -o json"
    'rg-disks'            = "az disk list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup,diskState:diskState,diskSizeGb:diskSizeGb,sku:{name:sku.name}}`" -o json"
    'rg-public-ips'       = "az network public-ip list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup,sku:{name:sku.name},publicIPAllocationMethod:publicIPAllocationMethod,ipConfiguration:ipConfiguration}`" -o json"
    'rg-app-plans'        = "az appservice plan list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup,sku:{name:sku.name},numberOfWorkers:numberOfWorkers,numberOfSites:numberOfSites}`" -o json"
    'rg-webapps'          = "az webapp list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup,appServicePlanId:appServicePlanId}`" -o json"
    'rg-sql-servers'      = "az sql server list -g `"{0}`" --subscription `"$SubscriptionId`" --query `"[].{id:id,name:name,location:location,resourceGroup:resourceGroup}`" -o json"
}

# --- Subscription-wide queries filtered client-side -------------------------
# Advisor has no --resource-group filter, so we pull all and filter by
# resourceMetadata.resourceId. If the caller only has RG-level Reader,
# Azure still returns Advisor items for the RGs they can read (or we fall back
# cleanly if a subscription-level endpoint denies access).
$subWide = [ordered]@{
    'rg-advisor-security'    = "az advisor recommendation list --category Security --subscription `"$SubscriptionId`" -o json"
    'rg-advisor-reliability' = "az advisor recommendation list --category HighAvailability --subscription `"$SubscriptionId`" -o json"
    'rg-advisor-cost'        = "az advisor recommendation list --category Cost --subscription `"$SubscriptionId`" -o json"
    'rg-advisor-performance' = "az advisor recommendation list --category Performance --subscription `"$SubscriptionId`" -o json"
    'rg-security-alerts'     = "az security alert list --subscription `"$SubscriptionId`" -o json"
}

function Invoke-AzJson {
    param([string]$Command, [string]$Label)
    $errFile = Join-Path $env:TEMP ("rgcollect-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    $cmdLine = '{0} < nul 2>"{1}"' -f $Command, $errFile
    $outLines = cmd /c $cmdLine
    $exit = $LASTEXITCODE
    $out = if ($outLines) { $outLines -join "`n" } else { '' }

    $warn = ''
    if (Test-Path $errFile) {
        $warn = Get-Content $errFile -Raw
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        Output  = $out
        Exit    = $exit
        Warning = $warn
    }
}

Write-Host "`nCollecting scoped data..." -ForegroundColor Cyan

foreach ($name in $perRg.Keys) {
    Write-Host ("  {0,-26}" -f $name) -NoNewline
    $merged = @()
    $anyFail = $false
    $anyWarn = $false

    foreach ($rg in $ResourceGroup) {
        $cmd = $perRg[$name].Replace('{0}', $rg)
        $r   = Invoke-AzJson -Command $cmd -Label $name

        if ($r.Exit -ne 0) { $anyFail = $true; continue }
        if ($r.Warning -and $r.Warning.Trim()) { $anyWarn = $true }
        if (-not $r.Output) { continue }

        try {
            $parsed = ($r.Output | ConvertFrom-Json)
            if ($null -ne $parsed) { $merged += @($parsed) }
        } catch { $anyFail = $true }
    }

    $path = Join-Path $OutDir "$name.json"
    if ($merged.Count -gt 0) {
        ConvertTo-Json -InputObject @($merged) -Depth 20 | Set-Content -Path $path -Encoding utf8
    } else {
        '[]' | Set-Content -Path $path -Encoding utf8
    }

    if ($anyFail)      { Write-Host ("PARTIAL ({0})" -f $merged.Count) -ForegroundColor Yellow }
    elseif ($anyWarn)  { Write-Host ("OK ({0}, warning ignored)" -f $merged.Count) -ForegroundColor Green }
    elseif ($merged.Count -eq 0) { Write-Host "empty" -ForegroundColor DarkGray }
    else               { Write-Host ("OK ({0})" -f $merged.Count) -ForegroundColor Green }
}

foreach ($name in $subWide.Keys) {
    Write-Host ("  {0,-26}" -f $name) -NoNewline
    $r = Invoke-AzJson -Command $subWide[$name] -Label $name
    $path = Join-Path $OutDir "$name.json"

    if ($r.Exit -ne 0) {
        Write-Host "FAILED" -ForegroundColor Yellow
        if ($r.Warning) {
            $r.Warning.Trim() -split "`n" | Select-Object -First 3 | ForEach-Object {
                Write-Host "    $_" -ForegroundColor DarkYellow
            }
        }
        '[]' | Set-Content -Path $path -Encoding utf8
        continue
    }

    $all = @()
    if ($r.Output) {
        try {
            $parsedAll = $r.Output | ConvertFrom-Json
            if ($null -ne $parsedAll) { $all = @($parsedAll) }
        } catch { $all = @() }
    }

    # Filter to scope. Advisor uses resourceMetadata.resourceId; alerts vary.
    $scoped = @()
    foreach ($item in $all) {
        $id = $null
        if ($item.resourceMetadata -and $item.resourceMetadata.resourceId) {
            $id = $item.resourceMetadata.resourceId
        } elseif ($item.id) {
            $id = $item.id
        }
        if (Test-InScope -ResourceId $id -ResourceGroups $ResourceGroup) {
            $scoped += $item
        }
    }

    if ($scoped.Count -gt 0) {
        ConvertTo-Json -InputObject @($scoped) -Depth 20 | Set-Content -Path $path -Encoding utf8
    } else {
        '[]' | Set-Content -Path $path -Encoding utf8
    }

    $suffix = if ($all.Count -gt 0) { " of $($all.Count) in subscription" } else { '' }
    if ($r.Warning -and $r.Warning.Trim()) {
        Write-Host ("OK ({0}{1}, warning ignored)" -f $scoped.Count, $suffix) -ForegroundColor Green
    } else {
        Write-Host ("OK ({0}{1})" -f $scoped.Count, $suffix) -ForegroundColor Green
    }
}

# --- Cost, scoped server-side via Cost Management ---------------------------
# Try subscription-scoped query filtered by ResourceGroupName first. If the
# caller only has Cost Management Reader at the Resource Group scope (e.g. an
# application team that does not own the subscription), fall back to querying
# each resource group's Cost Management endpoint directly and merging rows.
Write-Host ("  {0,-26}" -f 'rg-cost') -NoNewline

$subId = $SubscriptionId
if ($subId) {
    $from = (Get-Date).AddDays(-30).ToString('yyyy-MM-ddT00:00:00Z')
    $to   = (Get-Date).ToString('yyyy-MM-ddT23:59:59Z')

    # ResourceGroupName matching in Cost Management is case-sensitive in
    # practice, so submit both the supplied and lowercased forms.
    $rgValues = @()
    foreach ($rg in $ResourceGroup) {
        $rgValues += $rg
        if ($rg -cne $rg.ToLower()) { $rgValues += $rg.ToLower() }
    }

    $payload = @{
        type       = 'ActualCost'
        timeframe  = 'Custom'
        timePeriod = @{ from = $from; to = $to }
        dataset    = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
            grouping    = @(
                @{ type = 'Dimension'; name = 'ResourceGroupName' }
                @{ type = 'Dimension'; name = 'ServiceName' }
            )
            filter = @{
                dimensions = @{
                    name     = 'ResourceGroupName'
                    operator = 'In'
                    values   = $rgValues
                }
            }
        }
    } | ConvertTo-Json -Depth 12 -Compress

    $bodyFile = Join-Path $env:TEMP ("rg-cost-query-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $payload | Set-Content -Path $bodyFile -Encoding utf8

    $uri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
    $r = Invoke-AzJson -Command ('az rest --method post --uri "{0}" --headers "Content-Type=application/json" --body "@{1}" -o json' -f $uri, $bodyFile)
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

    $path = Join-Path $OutDir 'rg-cost.json'
    if ($r.Exit -eq 0 -and $r.Output) {
        $r.Output | Set-Content -Path $path -Encoding utf8
        Write-Host "OK" -ForegroundColor Green
    } else {
        # Fallback: query Cost Management per-RG scope in case the user only has RG-level cost permissions
        $mergedRows = @()
        $columns    = @(
            @{ name = 'Cost';              type = 'Number' }
            @{ name = 'ResourceGroupName'; type = 'String' }
            @{ name = 'ServiceName';       type = 'String' }
            @{ name = 'Currency';          type = 'String' }
        )
        $rgCostOk = $false

        $rgPayload = @{
            type       = 'ActualCost'
            timeframe  = 'Custom'
            timePeriod = @{ from = $from; to = $to }
            dataset    = @{
                granularity = 'None'
                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                grouping    = @(
                    @{ type = 'Dimension'; name = 'ServiceName' }
                )
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $rgBodyFile = Join-Path $env:TEMP ("rg-cost-perrg-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $rgPayload | Set-Content -Path $rgBodyFile -Encoding utf8

        foreach ($rg in $ResourceGroup) {
            $rgUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
            $rgRes = Invoke-AzJson -Command ('az rest --method post --uri "{0}" --headers "Content-Type=application/json" --body "@{1}" -o json' -f $rgUri, $rgBodyFile)
            if ($rgRes.Exit -eq 0 -and $rgRes.Output) {
                try {
                    $parsedRg = $rgRes.Output | ConvertFrom-Json
                    $rgCostOk = $true
                    if ($parsedRg.properties.rows) {
                        $cNames = $parsedRg.properties.columns.name
                        $idxCost = [array]::IndexOf($cNames, 'Cost')
                        $idxSvc  = [array]::IndexOf($cNames, 'ServiceName')
                        $idxCur  = [array]::IndexOf($cNames, 'Currency')
                        foreach ($row in $parsedRg.properties.rows) {
                            $cVal = if ($idxCost -ge 0) { $row[$idxCost] } else { 0 }
                            $sVal = if ($idxSvc  -ge 0) { $row[$idxSvc]  } else { '' }
                            $uVal = if ($idxCur  -ge 0) { $row[$idxCur]  } else { 'USD' }
                            $mergedRows += , @($cVal, $rg, $sVal, $uVal)
                        }
                    }
                } catch {}
            }
        }
        Remove-Item $rgBodyFile -Force -ErrorAction SilentlyContinue

        if ($rgCostOk) {
            $synthetic = @{
                properties = @{
                    columns = $columns
                    rows    = $mergedRows
                }
            }
            $synthetic | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding utf8
            Write-Host "OK (RG scope)" -ForegroundColor Green
        } else {
            '{}' | Set-Content -Path $path -Encoding utf8
            Write-Host "SKIPPED (needs Cost Management Reader)" -ForegroundColor DarkGray
        }
    }
} else {
    '{}' | Set-Content -Path (Join-Path $OutDir 'rg-cost.json') -Encoding utf8
    Write-Host "SKIPPED (not signed in)" -ForegroundColor DarkGray
}

Write-Host ""