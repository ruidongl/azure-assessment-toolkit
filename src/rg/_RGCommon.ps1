# Shared helpers for resource-group-scoped assessments.

$script:OutDir    = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'temp'
$script:ReportDir = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'reports'

function Read-Json {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    try {
        $raw = Get-Content $Path -Raw
        if (-not $raw -or -not $raw.Trim()) { return @() }
        $o = $raw | ConvertFrom-Json
        if ($null -eq $o) { return @() }
        return @($o)
    } catch { return @() }
}

function Get-RgFromResourceId {
    <#  Extracts the resource group segment from an ARM resource ID.  #>
    param([string]$ResourceId)
    if (-not $ResourceId) { return '' }
    $parts = $ResourceId -split '/'
    if ($parts.Count -ge 5) { return $parts[4] }
    return ''
}

function Test-InScope {
    <#  Case-insensitive match of a resource ID against the target RG list.  #>
    param(
        [string]$ResourceId,
        [string[]]$ResourceGroups
    )
    $rg = Get-RgFromResourceId $ResourceId
    if (-not $rg) { return $false }
    foreach ($t in $ResourceGroups) {
        if ($rg -ieq $t) { return $true }
    }
    return $false
}

function Get-ScopeLabel {
    param([string[]]$ResourceGroups)
    if ($ResourceGroups.Count -eq 1) { return $ResourceGroups[0] }
    return "$($ResourceGroups.Count) resource groups"
}

function Get-ScopeSlug {
    <#  Filename-safe identifier for the scope.  #>
    param([string[]]$ResourceGroups)
    if ($ResourceGroups.Count -eq 1) {
        return ($ResourceGroups[0] -replace '[^A-Za-z0-9_-]', '_')
    }
    return "MultiRG-$($ResourceGroups.Count)"
}