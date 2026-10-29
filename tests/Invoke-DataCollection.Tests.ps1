$collector = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Invoke-DataCollection.ps1'

Describe 'Subscription data collection' {
    BeforeEach {
        $script:originalTemp = $env:TEMP
        $script:originalPath = $env:PATH
        $script:originalSubscription = $env:AZURE_SUBSCRIPTION_ID
        $env:TEMP = Join-Path $TestDrive 'temporary files'
        New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
        $script:outDir = Join-Path $TestDrive 'output'
        $env:PATH = "$(Join-Path $PSScriptRoot 'fixtures');$env:PATH"
        $env:COLLECTION_TEST_MODE = 'success'
    }

    AfterEach {
        $env:TEMP = $script:originalTemp
        $env:PATH = $script:originalPath
        $env:AZURE_SUBSCRIPTION_ID = $script:originalSubscription
        $env:COLLECTION_TEST_MODE = $null
    }

    It 'collects successfully despite a locked legacy file and cleans temporary files' {
        $legacy = Join-Path $env:TEMP 'azcollect-advisor-security.err'
        $lock = [System.IO.File]::Open($legacy, 'Create', 'ReadWrite', 'None')
        try {
            $messages = (& $collector -OutDir $script:outDir 6>&1 | Out-String)
        } finally {
            $lock.Dispose()
            Remove-Item -LiteralPath $legacy
        }

        @(Get-ChildItem -LiteralPath $env:TEMP).Count | Should Be 0
        $disks = Get-Content (Join-Path $script:outDir 'disks.json') -Raw | ConvertFrom-Json
        $disks.Count | Should Be 2
        $cost = Get-Content (Join-Path $script:outDir 'consumption-usage.json') -Raw | ConvertFrom-Json
        $cost.Count | Should Be 2
        $cost[0].pretaxCost | Should Be 12.5
        $cost[0].meterDetails.meterCategory | Should Be 'Synthetic service'
        $messages | Should Match 'OK \(warning ignored\)'
        $messages | Should Not Match 'FAILED'
    }

    It 'prints cost API diagnostics and clears stale cost data on failure' {
        $env:COLLECTION_TEST_MODE = 'cost-failure'
        New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
        '[{"pretaxCost":999}]' | Set-Content (Join-Path $script:outDir 'consumption-usage.json')
        $messages = (& $collector -OutDir $script:outDir 6>&1 | Out-String)
        $messages | Should Match 'synthetic AuthorizationFailed'
        (Get-Content (Join-Path $script:outDir 'consumption-usage.json') -Raw).Trim() | Should Be '[]'
        @(Get-ChildItem -LiteralPath $env:TEMP).Count | Should Be 0
    }

    It 'reports an empty successful cost response as empty rather than failed' {
        $env:COLLECTION_TEST_MODE = 'empty-cost'
        $messages = (& $collector -OutDir $script:outDir 6>&1 | Out-String)
        $messages | Should Match 'consumption-usage\s+empty'
        $messages | Should Not Match 'FAILED'
    }

    It 'reports invalid cost JSON explicitly' {
        $env:COLLECTION_TEST_MODE = 'invalid-cost'
        $messages = (& $collector -OutDir $script:outDir 6>&1 | Out-String)
        $messages | Should Match 'FAILED'
        (Get-Content (Join-Path $script:outDir 'consumption-usage.json') -Raw).Trim() | Should Be '[]'
    }

    It 'rejects a cost response without rows' {
        $env:COLLECTION_TEST_MODE = 'missing-rows'
        $messages = (& $collector -OutDir $script:outDir 6>&1 | Out-String)
        $messages | Should Match 'no rows property'
    }

    It 'prints disk API diagnostics without retaining a partial inventory' {
        $env:COLLECTION_TEST_MODE = 'disk-failure'
        $messages = (& $collector -OutDir $script:outDir 6>&1 | Out-String)
        $messages | Should Match 'synthetic disk permission denied'
        (Get-Content (Join-Path $script:outDir 'disks.json') -Raw).Trim() | Should Be '[]'
    }
}
