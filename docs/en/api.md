# API reference

Use the Skopos HTTP API to integrate external tools and automation.
The API is under `/api/v1`.

## OpenAPI specification

Download the specification from your server:

```sh
curl --fail --silent --show-error https://skopos.example.org/api/v1/openapi.json \
  --output skopos-openapi.json
```

Replace the origin with your Skopos URL. The specification lists the installed
version's endpoints, inputs, responses, and permissions.

## Authentication

For authenticated operations, send `Authorization: Bearer TOKEN`.
Use the token issued by Skopos for your account.
Administrator, operator, and viewer permissions apply to API requests.

Monitoring webhooks use the secret of their configured Signal Provider.
They do not use an operator's token.

## Requests and results

Use the schema for the operation you call. Updates and decisions require the
current revision, and approval requests also require the proposal digest.
Read the current record before making a change.

When a request returns an ID before completion, follow that ID to its result.
After a lost response, check the original request before sending it again.

See [First-time setup](first-steps.md) for connection setup,
[Operations](operations.md) for incident handling, and [CLI](cli.md) for command access.
