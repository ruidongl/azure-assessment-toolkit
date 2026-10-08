# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-08

### Added

- Security assessment report — secure score, active alerts, recommendations by
  severity, Defender plan coverage
- Resiliency assessment report — Advisor high-availability findings, regional
  distribution, storage redundancy, VM zone placement, backup configuration
- Cost optimization report — 30-day spend by service, Advisor savings estimates,
  idle and orphaned resource detection (unattached disks, unassociated public
  IPs, stopped-not-deallocated VMs, empty App Service plans)
- `Get-RegionCost.ps1` for per-region cost breakdown via the Cost Management
  query API, with unfiltered location listing to resolve inconsistent billing
  labels
- `-Skip` parameter on `Invoke-Assessment.ps1` to omit individual pillars
- Preflight validation that all required scripts exist before collection starts

### Fixed

- Azure CLI stderr warnings no longer abort collection. `az security alert list`
  emits `Subtype value AAD has no mapping, use base class ResourceIdentifier`,
  which `$ErrorActionPreference = 'Stop'` converted into a terminating
  `NativeCommandError`. stderr is now diverted to a temp file so captured JSON
  stays clean and warnings are reported as `OK (warning ignored)`.
- Missing report scripts are now reported explicitly instead of being silently
  skipped, which previously produced a partial run with no indication a pillar
  had failed.