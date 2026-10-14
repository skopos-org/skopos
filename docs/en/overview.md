# Overview

Skopos is an AI-powered platform for autonomous infrastructure incident resolution,
from the first alert to verified recovery. It reduces the burden of 24/7 Network
Operations Center (NOC) operations by investigating incidents, carrying out
permitted remediation, and checking whether the affected systems have recovered.

AI chooses the next investigation or action from observations and previous
results, rather than following a predefined runbook. When recovery cannot be
confirmed within the configured authority and limits, Skopos hands the incident
to a human with the evidence collected. Scheduled audits can also discover
problems that monitoring has not reported.

## Connections to your environment

```text
Monitoring systems ── alerts ──> Skopos <── requests / results ──> AI services
                                   │
                  ┌────────────────┴──────────────────┐
                  │                                   │
          observations / changes              authenticated API
                  │                                   │
                  ▼                                   ▼
       Managed infrastructure                    Web and CLI
     Linux · Kubernetes · IOS XE                     Operators
```

Monitoring systems deliver alerts through configured Signal connections. Skopos
uses AI connections to interpret evidence and decide how to investigate or
remediate an incident. Target connections provide access to the managed systems
for observations, permitted changes, and fresh recovery checks. Skopos works with
your existing monitoring and infrastructure; operators configure these
connections and control the scope and authority of automation.

Connection protocols are selected independently of device identity. Linux can
use SSH, Kubernetes uses its API, and Cisco IOS XE can use SSH/CLI, NETCONF, or
RESTCONF. Check each configured connection against your environment; a connection
check does not verify every device version or operation.

## Incident history and control

The Web interface and CLI connect to the same authenticated server API. Operators
can follow incidents, review proposed changes, approve actions in Ask mode, and
inspect recovery results and reports.

An incident is tracked as a **Case**. Its history records observations, AI
decisions, proposed changes, operations, verification attempts, and reports.
**Targets** represent managed infrastructure. Their **Access Methods** identify
how Skopos connects to them, and **Providers** hold connection configuration and
credentials for AI, monitoring, target access, inventory, and notifications.

## Start here

1. [Install from source with Docker Compose](installation.md).
2. [Review runtime configuration](configuration.md).
3. [Create the initial administrator and connect your environment](first-steps.md).
4. [Inspect Cases and maintain the installation](operations.md).
5. [Use the CLI](cli.md) when working from a terminal.

For integration details, see the [API reference](api.md).

For changes to the project or these guides, see [Contributing](contributing.md).
Skopos is licensed under [Apache-2.0](../../LICENSE).
