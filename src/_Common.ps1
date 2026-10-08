function Read-Json {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Warning "Missing: $Path"; return @() }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try   { return @($raw | ConvertFrom-Json) }
    catch { Write-Warning "Invalid JSON: $Path"; return @() }
}