# Azure Resiliency Assessment

> **SAMPLE OUTPUT — fabricated data.** Resource names, identifiers, and findings
> on this page are invented for documentation purposes.

**Assessment Date:** March 14, 2026
**Subscription:** Contoso Platform Sandbox (`00000000-0000-0000-0000-000000000000`)
**Data Source:** Azure Advisor (HighAvailability) + resource inventory

---

## Executive Summary

| Metric | Value |
|--------|-------|
| **Reliability recommendations** | **34** |
| - High impact | 8 |
| - Medium impact | 19 |
| - Low impact | 7 |
| Total resources | 94 |
| Regions in use | 3 |
| Recovery Services vaults | 2 |
| Storage accounts | 11 |
| - Locally redundant (LRS) | 8 |
| - Zone or geo redundant | 3 |

---

## Regional Distribution

| Region | Resources | Share |
|--------|-----------|-------|
| East US | 61 | 64.9% |
| West US 2 | 28 | 29.8% |
| West Europe | 5 | 5.3% |

---

## Top Reliability Recommendations

| Count | Impact | Recommendation |
|-------|--------|----------------|
| 8 | High | Use zone-redundant storage for critical data |
| 6 | High | Enable backup on virtual machines |
| 5 | Medium | Deploy virtual machines across availability zones |
| 4 | Medium | Configure geo-replication for SQL databases |
| 4 | Medium | Enable autoscale on App Service plans |
| 3 | Low | Add health probes to load balancer rules |

---

## Storage Redundancy

| Storage Account | Region | SKU | Assessment |
|-----------------|--------|-----|------------|
| `contosostgweb01` | East US | Standard_LRS | Single-zone — consider ZRS |
| `contosostgarchive` | East US | Standard_GRS | Geo-redundant |
| `contosostglogs` | East US | Standard_LRS | Single-zone — consider ZRS |
| `contosostgdr` | West US 2 | Standard_ZRS | Zone-redundant |

---

## Virtual Machine Availability

| VM | Region | Zone | Availability Set | Backup |
|----|--------|------|------------------|--------|
| `contoso-web-prod` | East US | 1 | — | Enabled |
| `contoso-app-prod` | East US | — | `avset-app-prod` | Enabled |
| `contoso-sql-prod` | East US | 2 | — | Enabled |
| `contoso-vm-build01` | West US 2 | — | — | Not configured |

---

## Notes

- Findings are advisory. Validate against your own RTO and RPO targets — not
  every single-instance VM requires an availability set.
- LRS is appropriate for reproducible data such as build artifacts or caches.
  The recommendation matters most for data that cannot be regenerated.
- A resource appearing in only one region is not automatically a gap. Confirm
  whether a documented DR plan covers it before raising it as a finding.

**Query Timestamp:** 2026-03-14 09:24:03