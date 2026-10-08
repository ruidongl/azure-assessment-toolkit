# Contributing

## Before opening a PR

Confirm no generated output is staged:

```powershell
git status --porcelain
git diff --cached --name-only
```

Nothing from `reports/`, `temp/`, or `archive/` may appear.

Scan your diff for identifiers:

```powershell
git diff --cached | Select-String -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
```

Any GUID that is not `00000000-0000-0000-0000-000000000000` needs review before
you push.

## Test data

Samples and fixtures must be **fabricated from scratch** — invented names such as
`contoso-web-prod`, placeholder GUIDs.

Do not redact a real capture. Redaction reliably misses resource group names,
SKU patterns, and custom domains.

## Style

- PowerShell 5.1 compatible. No PS7-only syntax (`??`, `?.`, ternary).
- `$ErrorActionPreference = 'Continue'` in every script. The Azure CLI writes
  benign warnings to stderr, and `Stop` turns those into terminating
  `NativeCommandError` failures that abort collection mid-run.
- Approved verbs: `Get-`, `New-`, `Invoke-`.
- Pass `Invoke-ScriptAnalyzer -Path .\src -Recurse -Severity Error,Warning`.

## Adding a query

1. Add an entry to `$queries` in `Invoke-DataCollection.ps1`.
2. Consume it via `Read-Json` in the relevant report script.
3. Handle the empty case — `Read-Json` returns `@()` on missing or invalid input,
   so every section must render something when the array is empty.
4. Add a synthetic fixture under `tests/fixtures/`.
5. Document the API in the README table.

## Running tests

```powershell
Install-Module Pester -Force -Scope CurrentUser
Invoke-Pester .\tests
```

Tests run against fixtures only and never call Azure.