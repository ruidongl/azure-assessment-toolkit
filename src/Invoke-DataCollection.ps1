[CmdletBinding()]
param(
    [Alias('Subscription','s')]
    [string]$SubscriptionId,
    [string]$OutDir = './temp'
)

# Do not change to 'Stop'. az writes warnings to stderr on several commands.
$ErrorActionPreference = 'Continue'

function Invoke-CollectionCommand {
    param([string]$Command)

    $errFile = Join-Path $env:TEMP ("azcollect-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    try {
        # Disable stdin prompts and keep CLI warnings out of the JSON output.
        $cmdLine = '{0} < nul 2>"{1}"' -f $Command, $errFile
        $output = cmd /d /c $cmdLine
        $exitCode = $LASTEXITCODE
        $warning = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
        [pscustomobject]@{
            Output  = $output
            Exit    = $exitCode
            Warning = $warning
        }
    } finally {
        if (Test-Path $errFile) {
            Remove-Item $errFile -Force
        }
    }
}

function Write-CollectionFailure {
    param([string]$Detail)

    Write-Host "FAILED" -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        $Detail = 'No error details were returned by Azure CLI.'
    }
    $Detail.Trim() -split "`n" | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkYellow
    }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

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
$ctx | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutDir 'subscription.json') -Encoding utf8

$usageStart = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
$usageEnd   = (Get-Date).ToString('yyyy-MM-dd')

$queries = [ordered]@{
    'advisor-security'    = "az advisor recommendation list --category Security --subscription `"$SubscriptionId`" -o json"
    'advisor-reliability' = "az advisor recommendation list --category HighAvailability --subscription `"$SubscriptionId`" -o json"
    'advisor-cost'        = "az advisor recommendation list --category Cost --subscription `"$SubscriptionId`" -o json"
    'advisor-performance' = "az advisor recommendation list --category Performance --subscription `"$SubscriptionId`" -o json"
    'secure-score'        = "az security secure-scores list --subscription `"$SubscriptionId`" -o json"
    'secure-controls'     = "az security secure-score-controls list --subscription `"$SubscriptionId`" -o json"
    'security-alerts'     = "az security alert list --subscription `"$SubscriptionId`" -o json"
    'defender-pricing'    = "az security pricing list --subscription `"$SubscriptionId`" -o json"
    'resources'           = "az resource list --subscription `"$SubscriptionId`" --query `"[].{name:name,type:type,location:location}`" -o json"
    'recovery-vaults'     = "az backup vault list --subscription `"$SubscriptionId`" --query `"[].{name:name,location:location}`" -o json"
    'storage-accounts'    = "az storage account list --subscription `"$SubscriptionId`" --query `"[].{name:name,location:location,sku:{name:sku.name}}`" -o json"
    'vms'                 = "az vm list -d --subscription `"$SubscriptionId`" --query `"[].{name:name,location:location,zones:zones,hardwareProfile:{vmSize:hardwareProfile.vmSize},powerState:powerState}`" -o json"
    'public-ips'          = "az network public-ip list --subscription `"$SubscriptionId`" --query `"[].{name:name,location:location,sku:{name:sku.name},publicIPAllocationMethod:publicIPAllocationMethod,ipConfiguration:ipConfiguration}`" -o json"
    'app-service-plans'   = "az appservice plan list --subscription `"$SubscriptionId`" --query `"[].{name:name,location:location,sku:{name:sku.name},numberOfWorkers:numberOfWorkers,numberOfSites:numberOfSites}`" -o json"
}

Write-Host "Collecting data..." -ForegroundColor Cyan

foreach ($name in $queries.Keys) {
    $path = Join-Path $OutDir "$name.json"
    Write-Host ("  {0,-22}" -f $name) -NoNewline

    $commandResult = Invoke-CollectionCommand -Command $queries[$name]
    $result = $commandResult.Output
    $warn = $commandResult.Warning

    if ($commandResult.Exit -ne 0) {
        Write-CollectionFailure -Detail $warn
        '[]' | Set-Content -Path $path -Encoding utf8
        continue
    }

    if (-not $result) {
        Write-Host "empty" -ForegroundColor DarkGray
        '[]' | Set-Content -Path $path -Encoding utf8
        continue
    }

    $result | Set-Content -Path $path -Encoding utf8

    if ($warn -and $warn.Trim()) {
        Write-Host "OK (warning ignored)" -ForegroundColor Green
    } else {
        Write-Host "OK" -ForegroundColor Green
    }
}

# Collect managed disks via ARM REST API with nextLink pagination.
# Avoids 'az graph query' (which hangs waiting to install the resource-graph extension and caps at 1000 rows)
# and avoids 'az disk list' (which requires --resource-group in newer Azure CLI versions).
Write-Host ("  {0,-22}" -f 'disks') -NoNewline
$disksPath = Join-Path $OutDir 'disks.json'
$diskUri   = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/disks?api-version=2023-04-02"
$diskQuery = "{value:value[].{name:name,location:location,diskState:properties.diskState,diskSizeGb:properties.diskSizeGB,sku:{name:sku.name}},nextLink:nextLink}"
$allDisks  = [System.Collections.Generic.List[object]]::new()
$diskOk    = $true
$diskError = ''

while ($diskUri) {
    $command = 'az rest --method get --uri "{0}" --query "{1}" -o json' -f $diskUri, $diskQuery
    $commandResult = Invoke-CollectionCommand -Command $command
    $pageRaw = $commandResult.Output

    if ($commandResult.Exit -ne 0 -or -not $pageRaw) {
        $diskOk = $false
        $diskError = $commandResult.Warning
        break
    }

    try {
        $page = $pageRaw | ConvertFrom-Json
        if ($page.value) {
            foreach ($d in $page.value) {
                [void]$allDisks.Add($d)
            }
        }
        $diskUri = $page.nextLink
    } catch {
        $diskOk = $false
        $diskError = "Invalid disk response: $($_.Exception.Message)"
        break
    }
}

if ($diskOk) {
    if ($allDisks.Count -gt 0) {
        ConvertTo-Json -InputObject @($allDisks) -Depth 5 | Set-Content -Path $disksPath -Encoding utf8
        Write-Host "OK" -ForegroundColor Green
    } else {
        '[]' | Set-Content -Path $disksPath -Encoding utf8
        Write-Host "empty" -ForegroundColor DarkGray
    }
} else {
    '[]' | Set-Content -Path $disksPath -Encoding utf8
    Write-CollectionFailure -Detail $diskError
}

Write-Host ("  {0,-22}" -f 'consumption-usage') -NoNewline
$bodyPath = Join-Path $env:TEMP ("azcollect-cost-{0}.json" -f ([guid]::NewGuid().ToString('N')))
$costBody = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{
        from = "$($usageStart)T00:00:00Z"
        to   = "$($usageEnd)T00:00:00Z"
    }
    dataset    = @{
        granularity = 'None'
        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
        grouping    = @(@{ type = 'Dimension'; name = 'ServiceName' })
    }
}
$costBody | ConvertTo-Json -Depth 8 | Set-Content -Path $bodyPath -Encoding utf8

try {
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
    $command = 'az rest --method post --uri "{0}" --headers "Content-Type=application/json" --body "@{1}" -o json' -f $uri, $bodyPath
    $commandResult = Invoke-CollectionCommand -Command $command
    if ($commandResult.Exit -ne 0) {
        throw "Cost query failed (exit $($commandResult.Exit)): $($commandResult.Warning)"
    }
    $response = $commandResult.Output | ConvertFrom-Json -ErrorAction Stop
    if (-not $response -or -not $response.properties -or $null -eq $response.properties.rows) {
        throw 'Cost query returned no rows property. Check the Azure CLI response.'
    }

    if ($response.properties.rows.Count -gt 0) {
        $normalized = foreach ($row in $response.properties.rows) {
            [pscustomobject]@{
                pretaxCost  = $row[0]
                meterDetails = [pscustomobject]@{ meterCategory = $row[1] }
                currency    = $row[2]
            }
        }
        $normalized | ConvertTo-Json -Depth 4 |
            Set-Content -Path (Join-Path $OutDir 'consumption-usage.json') -Encoding utf8
        Write-Host "OK" -ForegroundColor Green
    } else {
        '[]' | Set-Content -Path (Join-Path $OutDir 'consumption-usage.json') -Encoding utf8
        Write-Host "empty" -ForegroundColor DarkGray
    }
} catch {
    '[]' | Set-Content -Path (Join-Path $OutDir 'consumption-usage.json') -Encoding utf8
    Write-CollectionFailure -Detail $_.Exception.Message
} finally {
    Remove-Item $bodyPath -Force -ErrorAction SilentlyContinue
}

Write-Host ""