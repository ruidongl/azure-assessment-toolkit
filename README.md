# Azure Assessment Toolkit

Read-only PowerShell scripts that generate three Markdown reports from any Azure subscription:

| Report | Covers |
|---|---|
| `SecurityAssessmentReport_YYYYMMDD.md` | Defender for Cloud secure score, active alerts, security recommendations, plan coverage |
| `ResiliencyAssessmentReport_YYYYMMDD.md` | Advisor high-availability findings, regional distribution, storage redundancy, VM zone placement |
| `CostOptimizationReport_YYYYMMDD.md` | 30-day spend, savings opportunities, idle and orphaned resources |

Everything runs locally under your own credentials. Nothing is transmitted anywhere.

---

## Quick start

```powershell
git clone https://github.com/<your-org>/azure-assessment-toolkit.git
cd azure-assessment-toolkit

az login --use-device-code
az account set --subscription "<SUBSCRIPTION-ID>"

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\src\Invoke-Assessment.ps1
```

Reports land in `./reports/`. Raw query output lands in `./temp/`.

---

## Prerequisites

| Requirement | Check |
|---|---|
| Azure CLI 2.50+ | `az version` |
| PowerShell 5.1+ | `$PSVersionTable.PSVersion` |
| Subscription access | see table below |

### Permissions

| Role | Enables |
|---|---|
| `Reader` | Security, resiliency, idle-resource detection |
| `Cost Management Reader` *or* `Billing Reader` | Spend analysis in the cost report |

No Owner or Contributor rights needed. Without a cost role the toolkit still runs — spend sections show `_not available_` and everything else populates normally.

Verify what you have:

```powershell
az consumption usage list --top 3 -o table
```

`AuthorizationFailed` means no cost role.

---

## Usage

### Full assessment

```powershell
.\src\Invoke-Assessment.ps1
.\src\Invoke-Assessment.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

### Skip pillars

```powershell
.\src\Invoke-Assessment.ps1 -Skip Cost
.\src\Invoke-Assessment.ps1 -Skip Security,Resiliency
```

### Individual steps

```powershell
.\src\Invoke-DataCollection.ps1      # collect only
.\src\New-SecurityReport.ps1         # regenerate from existing JSON
.\src\New-ResiliencyReport.ps1
.\src\New-CostReport.ps1
```

Report scripts read from `./temp/` and never call Azure, so they are fast to re-run while tuning output.

### Regional cost breakdown

```powershell
.\src\Get-RegionCost.ps1 -Region "West US"
.\src\Get-RegionCost.ps1 -Region "East US 2" -Days 60 -ShowAll
```

Prints every billing location first, then filters — billing labels are inconsistent (`West US`, `westus`, `US West`), so seeing the raw list removes the guesswork.

---

## What gets queried

Read-only ARM calls. No write operations. No secrets, keys, or data-plane content.

| API | Used for |
|---|---|
| `Microsoft.Advisor/recommendations` | Security, HighAvailability, Cost, Performance |
| `Microsoft.Security/secureScores` | Secure score |
| `Microsoft.Security/alerts` | Active alerts |
| `Microsoft.Security/pricings` | Defender plan coverage |
| `Microsoft.Consumption/usageDetails` | 30-day spend |
| `Microsoft.CostManagement/query` | Regional cost aggregation |
| `Microsoft.Compute/disks` | Unattached disks |
| `Microsoft.Network/publicIPAddresses` | Unassociated IPs |
| `Microsoft.Web/serverfarms` | Empty App Service plans |
| `Microsoft.Resources/resources` | Inventory |
| `Microsoft.RecoveryServices/vaults` | Backup configuration |

Runtime is 2–8 minutes. The consumption query is the slowest step.

---

## Output handling

> **Generated output contains your subscription ID, resource names, and resource group names.**

`.gitignore` excludes `reports/*` and `temp/*` so this never reaches a commit. If you fork and contribute, confirm those rules are intact before pushing.

```powershell
git status --porcelain
```

Should list nothing from `reports/` or `temp/`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `'security' is misspelled or not recognized` | Outdated CLI | `az upgrade` |
| `AuthorizationFailed` | Missing role | Request `Reader` on the subscription |
| `Please run 'az login'` | Token expired | Re-authenticate |
| `running scripts is disabled` | Execution policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `NativeCommandError` about stderr | `$ErrorActionPreference` is `Stop` | Open a fresh terminal; the scripts set `Continue` themselves |
| `consumption-usage  SKIPPED` | No billing role | Expected on `Reader` only |
| `reservations  SKIPPED` | Reservations live at billing-account scope | Harmless |
| Report shows `_No ... returned._` | Plan disabled or genuinely no data | `az security pricing list -o table` |

The Azure CLI writes benign warnings to stderr on several `az security` commands. The collector diverts stderr to a temp file so JSON stays clean, and reports these as `OK (warning ignored)`.

---

## Interpreting results

### Security

**Compare points, not percentage.** The maximum achievable secure score changes as Microsoft revises the scored control set. A rising percentage can accompany a falling score.

**Counts are per-resource.** One misconfiguration across 30 storage accounts appears as 30 findings.

**A disappearing finding is not proof of a fix.** It may also mean the resource was deleted, a Defender plan was disabled, or an exemption was applied.

### Resiliency

Findings are advisory. Validate against your own RTO/RPO targets — not every single-instance VM needs an availability set.

### Cost

**Savings are Advisor estimates**, derived from observed utilization, not guarantees.

**Reserved instance recommendations assume sustained usage.** Do not commit to a 1- or 3-year term based on a 30-day sample if workloads are seasonal or scheduled for migration.

**Validate idle resources before deleting.** An unattached disk may hold recoverable data. An unassociated public IP may be reserved for a planned cutover.

**`Stopped` still bills for compute.** Only `Stopped (deallocated)` halts charges — a common and easily corrected source of waste.

**Right-sizing has a resiliency trade-off.** Downsizing to match average utilization removes headroom for spikes. Cross-check against the resiliency report before acting.

**Region filters undercount.** Global services (Entra ID, Traffic Manager, DNS) bill to `Global` or an empty location. Egress often lands under `Unassigned`.

---

## Re-running

Safe to run repeatedly. To keep history for trending:

```powershell
$stamp = Get-Date -Format 'yyyyMMdd'
New-Item -ItemType Directory -Path ".\archive\$stamp" -Force | Out-Null
Copy-Item .\temp\*.json ".\archive\$stamp" -Force
```

`archive/` is gitignored. A bi-weekly or monthly cadence works well.

---

## Repository layout

```
src/        assessment scripts
docs/       extended documentation
samples/    example output with fabricated data
tests/      Pester tests and synthetic fixtures
reports/    generated output (gitignored)
temp/       raw query results (gitignored)
```

---

## Contributing

See `CONTRIBUTING.md`. Before opening a PR, confirm no generated output is staged:

```powershell
git diff --cached --name-only
```

Sample reports and test fixtures must use fabricated data — invented resource names, placeholder GUIDs. Do not redact a real capture; redaction reliably misses resource group names and SKU patterns.

---

## License

MIT. See `LICENSE`.