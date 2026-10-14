# Configuration

Use these settings when installing the server and connecting your environment.
Connection and authority settings can be managed through Web or CLI.

## Server settings

Set these values in the `.env` beside `compose.yaml`.

| Variable | Purpose | Value |
| --- | --- | --- |
| `SKOPOS_VERSION` | Container version | The selected release version, without `v` |
| `SKOPOS_IMAGE` | Container registry and image | `ghcr.io/skopos-org/skopos` |
| `POSTGRES_PASSWORD` | Database password | Required |
| `SKOPOS_CREDENTIALS_KEY` | Encrypts saved connection credentials | Required; Base64-encoded 32-byte key |
| `SKOPOS_TOKEN_SIGNING_SECRET` | Signs authentication tokens | Required |
| `SECRET_KEY_BASE` | Protects browser sessions | Required |
| `SKOPOS_PUBLIC_URL` | URL operators use to access Skopos | `http://localhost:4000` |
| `SKOPOS_PORT` | Host port | `4000` |
| `SKOPOS_CASE_COLLECT_SECONDS` | Alert collection window, in seconds | `5`; integer from `0` to `30` |

Use an HTTP(S) origin for `SKOPOS_PUBLIC_URL`, such as
`https://skopos.example.org`. Include a nonstandard port; omit paths and query
parameters. For HTTPS, configure your reverse proxy to forward HTTP and WebSocket
requests to the server's port 4000.

After changing server settings, run `docker compose up --no-build -d server`.
Keep the existing encryption and signing secrets.

## Connections

| Connection | What to configure |
| --- | --- |
| AI | Service, model, credentials, and Resolver/Reviewer role |
| Monitoring | Webhook adapter, source name, and webhook secret |
| Target access | Protocol, endpoint, authentication, and permitted capabilities |
| Inventory | Inventory source and credentials, when importing Targets |
| Notification | Destination and credentials, when delivering reports |

Register managed infrastructure as Targets and attach access methods.
Use external identities to associate monitoring labels with those Targets.

## Authority and limits

| Mode | How changes are authorized |
| --- | --- |
| Read only | Observe without changing managed systems |
| Ask | An operator approves each proposed change |
| Auto | An assigned Reviewer approves each proposed change |
| Full access | Changes can run without human or Reviewer approval |

Assign a Resolver to investigate and remediate Cases. Auto mode also needs a
Reviewer. Select **Both (Resolver and Reviewer)** to use one connection for both roles.

Set limits for elapsed time, Resolver turns, Target requests, changes, related
Targets, AI usage, and turns without progress.

**Start resolution from incoming Signals** controls whether received alerts
start resolution automatically. Configure connections and authority before
enabling it.

## CLI setup inputs

The [CLI setup path](first-steps.md#cli) uses the files below.
Replace the example endpoints, credentials, IDs, and revisions with your values.
The SSH and generic webhook examples illustrate one connection choice;
use the protocol appropriate to your environment.

### AI connection: ai.json

Choose a service from `skopos provider services` and its model. This example
assigns an OpenAI connection to both AI roles.

```json
{
  "name": "Incident AI",
  "kind": "ai",
  "adapter_type": "req-llm",
  "configuration": {"provider": "openai", "model": "MODEL_ID"},
  "credentials": {"api_key": "API_KEY"},
  "usage_scope": "all",
  "usage_priority": 100
}
```

### Target: target.json

Use `skopos target-type list` to select the Target's `type_id` and `kind`.
This example registers a host with a custom operating system.

```json
{"name": "managed-01", "type_id": "custom-os", "kind": "host"}
```

### Target connection: target-provider.json

For SSH, provide the trusted host-key fingerprint for the exact endpoint.

```json
{
  "name": "Managed SSH",
  "kind": "target",
  "adapter_type": "ssh",
  "configuration": {
    "host_key_fingerprints": {
      "ssh://managed.example.org:22": "SHA256:HOST_KEY_FINGERPRINT"
    }
  },
  "credentials": {
    "username": "skopos",
    "auth_method": "password",
    "password": "PASSWORD"
  }
}
```

### Access method: method.json

Use the Target and Provider IDs returned by registration. Read the Provider's
current revision with `skopos provider show PROVIDER_ID`.

```json
{
  "target_id": "TARGET_ID",
  "provider_id": "TARGET_PROVIDER_ID",
  "provider_revision": 1,
  "name": "SSH access",
  "method": "ssh",
  "endpoint": "ssh://managed.example.org:22",
  "capabilities": ["request.ssh.effect"]
}
```

### Monitoring connection: signal.json

```json
{
  "name": "Monitoring",
  "kind": "signal",
  "adapter_type": "generic-webhook",
  "configuration": {"source": "monitoring"},
  "credentials": {"secret": "WEBHOOK_SECRET_AT_LEAST_16_CHARACTERS"}
}
```

For this adapter, use `https://YOUR_SKOPOS/api/v1/signals/generic/SIGNAL_PROVIDER_ID` and
`Authorization: Bearer WEBHOOK_SECRET`. Use the payload format for the selected
adapter in the [API specification](api.md).

### Monitoring identity: identity.json

Use the same source, identity kind, and value as the incoming alert's Target reference.

```json
{
  "target_id": "TARGET_ID",
  "source": "monitoring",
  "kind": "hostname",
  "value": "managed.example.org"
}
```

### Connection checks: revision.json

Use the current `revision` returned by `provider show` or `access-method show`.
Refresh this value before checking or enabling a connection.

```json
{"expected_revision": 1}
```

### Authority: authority.json

Read `setting_revision` with `skopos authority show` and use it as
`expected_setting_revision`. Choose limits for your environment; these values
illustrate Ask mode with automatic alert resolution disabled.

```json
{
  "expected_setting_revision": 1,
  "authority_mode": "ask",
  "signal_automation_enabled": false,
  "max_elapsed_seconds": 3600,
  "max_resolver_turns": 20,
  "max_target_requests": 100,
  "max_effects": 10,
  "max_related_targets": 20,
  "max_ai_usage_units": 1000000,
  "max_no_progress_turns": 3,
  "reason": "Initial setup"
}
```

### First Case: case.json

Describe the observed problem and a result Skopos can verify.
Give each manual submission its own `source_ref`.

```json
{
  "trigger_kind": "manual",
  "source": "cli",
  "source_ref": "initial-check-001",
  "title": "Investigate the managed system",
  "severity": "info",
  "initial_target_id": "TARGET_ID",
  "initial_context": {
    "observed_problem": "Describe the symptom you observed",
    "desired_outcome": "Describe the observable condition that confirms recovery"
  }
}
```
