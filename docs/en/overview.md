# Overview

Skopos uses AI to resolve infrastructure incidents, from the first alert to
verified recovery. It takes on investigation and remediation to reduce the
burden of 24/7 Network Operations Center (NOC) operations.

AI chooses its next action from the observed state and previous results.
Skopos carries out permitted changes and checks whether they restored the
affected system. If it cannot complete the response within your authority and
limits, it hands the incident to an operator with the collected evidence.

## How Skopos connects

```text
Monitoring systems ── alerts ──> Skopos <── requests / results ──> AI services
                                   │
                  ┌────────────────┴──────────────────┐
                  │                                   │
          observations / changes              authenticated API
                  │                                   │
                  ▼                                   ▼
         Your infrastructure                     Web and CLI
                                                    Operators
```

Connect your monitoring system, AI service, and managed infrastructure to Skopos.
Choose access methods such as SSH, HTTP APIs, NETCONF, RESTCONF, Redfish, or IPMI
to match the system you manage. Add multiple access methods when needed.

## What you control

- **Incident response:** investigate, remediate, and verify recovery in one Case.
- **Authority:** allow observation only, require human approval, require AI review,
  or permit changes without approval.
- **Limits:** bound response time, actions, related Targets, and AI usage.
- **Audits:** schedule investigations without waiting for an alert.
- **Evidence:** review observations, decisions, changes, and recovery results.

Configure and operate Skopos through Web or CLI.

## Get started

1. [Install Skopos](installation.md).
2. [Connect your environment using Web or CLI](first-steps.md).
3. [Manage incidents and audits](operations.md).

See [Configuration](configuration.md) for settings, [CLI](cli.md) for command
usage, and [API reference](api.md) for integrations.

For development, see [Contributing](contributing.md).
Skopos is licensed under [Apache-2.0](../../LICENSE).
