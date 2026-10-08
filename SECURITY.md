# Security Policy

## Scope

This toolkit performs **read-only** queries against Azure Resource Manager. It
performs no write operations and reads no secrets, keys, or data-plane content.

## Handling generated output

Files written to `reports/` and `temp/` contain:

- Subscription and tenant identifiers
- Resource, resource group, and custom domain names
- Unremediated security findings

Treat this output as **confidential**. It describes exploitable weaknesses in a
live environment, which is exactly the information an attacker would want.

- `.gitignore` excludes both directories. Verify before every push.
- Do not attach raw output to public issues.
- Redact before sharing externally, or share only aggregate counts.
- Delete `temp/` when an engagement ends.

## Reporting a vulnerability

Open a GitHub issue for defects in the scripts themselves.

**Do not** include real subscription IDs, resource names, or report output in an
issue. Reproduce with fabricated values.

For a vulnerability in the toolkit that could expose customer data, report
privately through GitHub Security Advisories rather than a public issue.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | Yes |