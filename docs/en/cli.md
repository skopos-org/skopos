# CLI

Use the CLI to configure connections and authority, manage Targets, respond to
incidents, schedule audits, and read reports.

[Install the CLI](installation.md), then follow [First-time setup](first-steps.md#cli)
to connect it to a server and configure your environment.

## Commands

| Task | Commands |
| --- | --- |
| Server and sign-in | `config set-server`, `config show`, `auth login`, `auth status`, `auth logout` |
| Accounts | `account list`, `account create`, `account change-role` |
| Connections | `provider services`, `provider list`, `provider create`, `provider check`, `provider enable`, `provider update` |
| AI roles and authority | `ai-role list`, `provider usage`, `authority show`, `authority set` |
| Targets | `target-type list`, `target create`, `target list`, `target show`, `target update` |
| Access methods | `access-method create`, `access-method check`, `access-method list`, `access-method update` |
| Identities and relationships | `identity create`, `identity list`, `relationship create`, `relationship list` |
| Inventory | `inventory preview-manual`, `inventory preview-provider`, `inventory rows`, `inventory apply` |
| Incidents | `case create`, `case show`, `case timeline`, `case resume`, `case cancel` |
| Decisions and results | `proposal show`, `proposal decide`, `operation show`, `verification show` |
| Monitoring | `signal list`, `signal show`, `signal events` |
| Audits | `audit schedule`, `audit list`, `audit-run list`, `audit-run show` |
| Reports and delivery | `report list`, `report read`, `report summary`, `delivery create`, `delivery show` |
| Target files | `file upload`, `file list`, `file download`, `file revoke` |

Run `skopos --help` for command syntax.

## Inputs and output

For a command that changes state, pass a JSON object using `--input FILE` or
`--input -` for standard input. Specify the resource fields directly, as in the
[configuration examples](configuration.md).

List commands return a page of results. Use `--limit` and `--after` to continue
through a list. Use the returned IDs and current revisions for subsequent commands.

Provider and audit-schedule registration commands print their registration ID
to standard error before sending the request. Keep it so you can check the
original registration if its response is lost.

## Waiting for a result

```sh
skopos case wait CASE_ID --interval 1000 --timeout 60
skopos operation wait OPERATION_ID --interval 1000 --timeout 60
skopos verification wait VERIFICATION_ID --interval 1000 --timeout 60
skopos delivery wait DELIVERY_ID --interval 1000 --timeout 60
```

`--interval` is in milliseconds and `--timeout` is in seconds.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Succeeded or resolved |
| `2` | Invalid command usage |
| `3` | Authentication error |
| `4` | Rejected request or local error |
| `5` | Transport error |
| `10` | Accepted or resolving |
| `11` | Approval required |
| `12` | Needs attention |
| `13` | Failed |
| `14` | Partial |
| `15` | Unknown |
| `16` | Cancellation requested |

In automation, check the result status and IDs as well as the exit code.
A transport error or unknown result can occur after a remote change.
