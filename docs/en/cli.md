# CLI

The product CLI is an authenticated client of the Skopos server API. Its command
language and JSON output are fixed English; `report read` prints the report's own
language.

## Run from source

With the repository's Elixir/Erlang toolchain installed, fetch the CLI dependencies
and display help:

```sh
MIX_ENV=cli mix deps.get
MIX_ENV=cli mix run --no-halt -- --help
```

Prefix commands below with `MIX_ENV=cli mix run --no-halt --` when running from
source. For example:

```sh
MIX_ENV=cli mix run --no-halt -- config set-server http://localhost:4000
MIX_ENV=cli mix run --no-halt -- auth login
MIX_ENV=cli mix run --no-halt -- auth status
```

Login opens the server's browser authentication flow and saves a session locally.
Use `config show` to inspect the configured server and authentication status;
`auth logout` signs out the CLI session.

## Read current state

The following uses `skopos` as shorthand for the source invocation above:

```sh
skopos target list --limit 20
skopos provider list --limit 20
skopos case list --limit 20
skopos case show CASE_ID
skopos case wait CASE_ID --interval 1000 --timeout 60
skopos operation show OPERATION_ID
skopos operation wait OPERATION_ID --interval 1000 --timeout 60
```

Replace the identifiers with IDs returned by the server. List commands paginate
using `--limit` and `--after`. Waiting polls existing work; it does not resubmit
the operation.

Mutation commands accept `--input FILE` or `--input -` for JSON on standard input.
The input contains resource fields directly; the CLI adds the API envelope.
Provider and audit-schedule registration IDs are emitted to standard error before
dispatch. Retain those IDs to check the original registration after a lost
response.

## Exit status

| Code | Meaning |
| --- | --- |
| `0` | Succeeded or resolved |
| `2` | Usage error |
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

Automation should inspect the returned status and identifiers as well as the exit
code. In particular, transport failure or `unknown` does not prove that a remote
effect did not occur.
