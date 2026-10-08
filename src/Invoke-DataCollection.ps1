[CmdletBinding()]
param([string]$OutDir = './temp')

# Do not change to 'Stop'. az writes warnings to stderr on several commands.
$ErrorActionPreference = 'Continue'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$queries = [ordered]@{
    'advisor-security'    = 'az advisor recommendation list --category Security -o json'
    'advisor-reliability' = 'az advisor recommendation list --category HighAvailability -o json'
    'secure-score'        = 'az security secure-scores list -o json'
    'secure-controls'     = 'az security secure-score-controls list -o json'
    'security-alerts'     = 'az security alert list -o json'
    'defender-pricing'    = 'az security pricing list -o json'
    'resources'           = 'az resource list -o json'
    'recovery-vaults'     = 'az backup vault list -o json'
    'storage-accounts'    = 'az storage account list -o json'
    'vms'                 = 'az vm list -d -o json'
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

Write-Host ""