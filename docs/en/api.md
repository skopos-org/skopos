# API reference

The Web interface and CLI use the Skopos HTTP API under `/api/v1`. Use the OpenAPI
specification from your installed server to inspect its endpoints, request
schemas, response schemas, and authentication requirements:

```sh
curl --fail --silent --show-error http://localhost:4000/api/v1/openapi.json \
  --output skopos-openapi.json
```

Replace the origin with your server's public URL. The specification endpoint is
public and describes the running version of Skopos.

## Authentication and permissions

Authenticated endpoints accept `Authorization: Bearer TOKEN`. Permissions depend
on the signed-in account and the operation. Public authentication and bootstrap
endpoints have their own requirements; Signal webhooks use the configured
Provider's webhook secret. Consult each operation's security definition in the
specification rather than treating all endpoints as interchangeable.

For interactive use, the [CLI](cli.md) handles browser login and authenticated
requests. Use [First-time setup](first-steps.md) to configure accounts, connections,
and authority, and [Configuration](configuration.md) for server startup settings.

## Follow asynchronous work

A successful submission may return a registration or operation identifier before
work finishes. Retain that identifier and inspect its status rather than
resubmitting after a lost response. An applied change still needs a recovery
check; `unknown` and `partial` results require inspecting the evidence and the
affected system. See [Operations](operations.md) and the CLI's status and wait
commands.
