# Skopos

Skopos is an AI-powered platform for autonomous infrastructure incident resolution,
from the first alert to verified recovery. It is designed to reduce the burden of
24/7 Network Operations Center (NOC) operations.

AI decides what to investigate and how to remediate each incident based on
observations, rather than following a predefined runbook. Skopos carries out
permitted changes, checks whether the affected systems have recovered, and uses
those results to decide the next step. It continues until recovery is confirmed
or the incident is handed to a human with the evidence collected.

Skopos works with your existing monitoring systems, AI services, and infrastructure.

## Features

- **Autonomous resolution** — AI adapts investigation and remediation to
  observations and previous action results, then verifies recovery.
- **Controlled autonomy** — Choose read-only investigation, human approval, AI
  review, or full access, with limits on time, actions, and AI usage.
- **Verified recovery** — Verify remediation with fresh observations from the
  affected systems.
- **Proactive audits** — Schedule investigations to find operational and security
  problems that monitoring has not reported.
- **Traceable response** — Keep evidence, decisions, approvals, actions, and
  recovery results together for review and handover.

Manage connections, follow incidents, and review results through the web
interface or CLI.

## Documentation

See the [documentation](https://skopos-org.github.io/skopos/) to install, configure,
and use Skopos.

## Contributing

See the [contributor guide](docs/en/contributing.md) for the development environment,
checks, and documentation preview commands. Use
[GitHub Issues](https://github.com/skopos-org/skopos/issues) to report problems or
discuss changes.

## License

Copyright 2026 Skopos contributors. Licensed under the
[Apache License, Version 2.0](LICENSE). Third-party components retain their
respective licenses and attribution.
