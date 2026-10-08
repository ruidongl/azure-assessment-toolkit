# Azure Cost Optimization Assessment

> **SAMPLE OUTPUT — fabricated data.** Resource names, identifiers, and figures
> on this page are invented for documentation purposes.

**Assessment Date:** March 14, 2026
**Subscription:** Contoso Platform Sandbox (`00000000-0000-0000-0000-000000000000`)
**Data Source:** Azure Advisor (Cost) + Consumption usage + resource inventory

---

## Executive Summary

| Metric | Value |
|--------|-------|
| **Spend, last 30 days** | **4,812.37 USD** |
| Projected annual run rate | 58,566.54 USD |
| **Identified annual savings** | **11,240.00 USD** |
| **Cost recommendations** | **17** |
| - High impact | 4 |
| - Medium impact | 9 |
| - Low impact | 4 |
| Unattached managed disks | 3 (640 GB) |
| Unassociated public IPs | 2 |
| Stopped (not deallocated) VMs | 1 |
| App Service plans with no apps | 1 |

Identified savings represent approximately **19.2%** of the projected annual run
rate.

---

## Cost Recommendations by Savings

| Annual Savings | Impact | Resource | Recommendation |
|----------------|--------|----------|----------------|
| 4,320.00 USD | High | `contoso-sql-prod` | Consider a reserved capacity purchase |
| 2,880.00 USD | High | `contoso-vm-build01` | Right-size or shut down underutilized VM |
| 1,560.00 USD | High | `asp-contoso-legacy` | Delete unused App Service plan |
| 1,104.00 USD | Medium | `contoso-app-stage` | Right-size underutilized virtual machine |
| 720.00 USD | Medium | `contosostgarchive` | Move infrequently accessed data to Cool tier |
| 396.00 USD | Low | `contoso-pip-legacy` | Delete unassociated public IP address |

---

## Spend by Service (last 30 days)

| Service | Cost | Share |
|---------|------|-------|
| Virtual Machines | 2,104.18 USD | 43.7% |
| SQL Database | 1,287.44 USD | 26.8% |
| Storage | 612.09 USD | 12.7% |
| App Service | 418.55 USD | 8.7% |
| Bandwidth | 221.76 USD | 4.6% |
| Key Vault | 98.20 USD | 2.0% |
| Log Analytics | 70.15 USD | 1.5% |

---

## Idle and Orphaned Resources

### Unattached managed disks (3)

| Disk | Region | Size (GB) | SKU |
|------|--------|-----------|-----|
| `contoso-vm-old01_OsDisk` | East US | 256 | Premium_LRS |
| `contoso-vm-old02_OsDisk` | East US | 256 | Premium_LRS |
| `contoso-data-tmp` | West US 2 | 128 | Standard_LRS |

### Unassociated public IP addresses (2)

| Name | Region | SKU | Allocation |
|------|--------|-----|------------|
| `contoso-pip-legacy` | East US | Standard | Static |
| `contoso-pip-test` | West US 2 | Basic | Dynamic |

### Stopped VMs still incurring compute charges (1)

A VM in `Stopped` state still bills for compute. Only `Stopped (deallocated)`
halts charges.

| VM | Region | Size | Power state |
|----|--------|------|-------------|
| `contoso-vm-build01` | West US 2 | Standard_D4s_v5 | VM stopped |

### App Service plans hosting no apps (1)

| Plan | Region | SKU | Workers |
|------|--------|-----|---------|
| `asp-contoso-legacy` | East US | P1v3 | 2 |

---

## Related Performance Findings

| Count | Impact | Recommendation |
|-------|--------|----------------|
| 3 | Medium | Upgrade to Premium SSD for improved IOPS |
| 2 | Low | Enable accelerated networking |

---

## Notes

- Savings figures are Azure Advisor estimates based on observed utilization, not
  guarantees.
- Reserved instance recommendations assume sustained usage. Do not commit to a
  1- or 3-year term based on a 30-day sample if workloads are seasonal or
  scheduled for migration.
- Validate idle resources before deletion. Unattached disks may hold recoverable
  data from a decommissioned VM.
- Right-sizing removes headroom for spikes. Cross-check against the resiliency
  report before acting.

**Query Timestamp:** 2026-03-14 09:26:18