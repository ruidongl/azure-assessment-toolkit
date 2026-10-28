[CmdletBinding()]
param([string]$OutDir = './temp')

# Do not change to 'Stop'. az writes warnings to stderr on several commands.
$ErrorActionPreference = 'Continue'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$usageStart = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
$usageEnd   = (Get-Date).ToString('yyyy-MM-dd')

$queries = [ordered]@{
    'advisor-security'    = 'az advisor recommendation list --category Security -o json'
    'advisor-reliability' = 'az advisor recommendation list --category HighAvailability -o json'
    'advisor-cost'        = 'az advisor recommendation list --category Cost -o json'
    'advisor-performance' = 'az advisor recommendation list --category Performance -o json'
    'secure-score'        = 'az security secure-scores list -o json'
    'secure-controls'     = 'az security secure-score-controls list -o json'
    'security-alerts'     = 'az security alert list -o json'
    'defender-pricing'    = 'az security pricing list -o json'
    'resources'           = 'az resource list --query "[].{name:name,type:type,location:location}" -o json'
    'recovery-vaults'     = 'az backup vault list -o json'
    'storage-accounts'    = 'az storage account list -o json'
    'vms'                 = 'az vm list -d -o json'
    'disks'               = 'az graph query -q "Resources | where type =~ ''microsoft.compute/disks'' | project name, location, diskState=tostring(properties.diskState), diskSizeGb=toint(properties.diskSizeGB), sku" --first 1000 --query data -o json'
    'public-ips'          = 'az network public-ip list -o json'
    'app-service-plans'   = 'az appservice plan list -o json'
}

Write-Host "Collecting data..." -ForegroundColor Cyan

foreach ($name in $queries.Keys) {
    $path    = Join-Path $OutDir "$name.json"
    $errFile = Join-Path $env:TEMP "azcollect-$name.err"
    Write-Host ("  {0,-22}" -f $name) -NoNewline

    # cmd /c keeps stderr out of the captured stdout so the JSON stays clean.
    $cmdLine = '{0} 2>"{1}"' -f $queries[$name], $errFile
    $result  = cmd /c $cmdLine
    $exit    = $LASTEXITCODE

    $warn = ''
    if (Test-Path $errFile) {
        $warn = (Get-Content $errFile -Raw)
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }

    if ($exit -ne 0) {
        Write-Host "FAILED" -ForegroundColor Yellow
        if ($warn) {
            $warn.Trim() -split "`n" | ForEach-Object {
                Write-Host "    $_" -ForegroundColor DarkYellow
            }
        }
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

Write-Host ("  {0,-22}" -f 'consumption-usage') -NoNewline
$ctx = az account show -o json 2>$null | ConvertFrom-Json
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
    $uri = "https://management.azure.com/subscriptions/$($ctx.id)/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
    $response = az rest --method post --uri $uri --headers 'Content-Type=application/json' `
        --body "@$bodyPath" -o json 2>$null | ConvertFrom-Json

    if ($LASTEXITCODE -eq 0 -and $response.properties.rows) {
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
        Write-Host "FAILED" -ForegroundColor Yellow
    }
} finally {
    Remove-Item $bodyPath -Force -ErrorAction SilentlyContinue
}

Write-Host ""