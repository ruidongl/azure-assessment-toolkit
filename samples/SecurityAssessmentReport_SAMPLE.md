# Azure Security Assessment

> **SAMPLE OUTPUT — fabricated data.** Resource names, identifiers, and findings
> on this page are invented for documentation purposes.

**Assessment Date:** March 14, 2026
**Subscription:** Contoso Platform Sandbox (`00000000-0000-0000-0000-000000000000`)
**Data Source:** Microsoft Defender for Cloud + Azure Advisor

---

## Executive Summary

| Metric | Value |
|--------|-------|
| **Secure Score** | **18.42 / 26** (70.8%) |
| **Active Alerts** | **7** |
| - High severity | 1 |
| - Medium severity | 4 |
| - Low severity | 2 |
| **Recommendations** | **112** |
| - High impact | 23 |
| - Medium impact | 61 |
| - Low impact | 28 |
| Total Resources | 94 |

---

## Active Security Alerts

| Severity | Alert | Affected Resource | First Detected |
|----------|-------|-------------------|----------------|
| High | Anomalous sign-in from unfamiliar location | `contoso-vm-build01` | 2026-03-11 |
| Medium | Suspicious PowerShell execution | `contoso-vm-build01` | 2026-03-12 |
| Medium | Access from a Tor exit node | `contoso-web-prod` | 2026-03-09 |
| Medium | Unusual data egress volume | `contosostgarchive` | 2026-03-07 |
| Medium | Brute force attempt against SQL | `contoso-sql-prod` | 2026-03-13 |
| Low | Deprecated TLS version negotiated | `contoso-api-prod` | 2026-02-28 |
| Low | Port scan detected | `contoso-vnet-hub` | 2026-03-02 |

> The high-severity alert is **3 days** old at time of assessment.

---

## Top Recommendations by Resource Count

| Count | Impact | Recommendation |
|-------|--------|----------------|
| 19 | High | Storage accounts should restrict network access |
| 14 | High | Management ports should be closed on virtual machines |
| 12 | Medium | Diagnostic logs should be enabled |
| 11 | Medium | Secure transfer to storage accounts should be enabled |
| 9 | High | SQL databases should have vulnerability assessment enabled |
| 8 | Medium | Key vaults should have soft delete enabled |
| 7 | Low | Resources should have tags applied |

---

## Defender Plan Coverage

| Plan | Status |
|------|--------|
| VirtualMachines | Standard |
| SqlServers | Standard |
| StorageAccounts | Standard |
| AppServices | Free |
| KeyVaults | Free |
| Containers | Free |
| Arm | Free |

Plans on `Free` provide alerting only — no vulnerability assessment or threat
protection.

---

## Notes

- Secure score reflects only controls Defender for Cloud evaluates. It is not a
  complete measure of security posture.
- Recommendation counts are per-resource. One misconfiguration applied across 19
  storage accounts appears as 19 findings.
- Compare **points earned** across assessments rather than percentage. The
  maximum achievable score changes as Microsoft revises the scored control set.

**Query Timestamp:** 2026-03-14 09:22:41