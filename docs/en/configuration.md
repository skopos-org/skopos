# Configuration

Server startup settings come from environment variables. AI connections,
monitoring connections, Target access, account roles, and AI authority are
configured through the Web interface after startup.

## Docker Compose settings

Set these in the repository-root `.env` file used by Compose:

| Variable | Purpose | Default or requirement |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | Password for the bundled PostgreSQL database | Required |
| `SKOPOS_CREDENTIALS_KEY` | Encryption key for saved credentials | Required; Base64-encoded 32-byte key |
| `SKOPOS_TOKEN_SIGNING_SECRET` | Signs authentication tokens | Required |
| `SECRET_KEY_BASE` | Phoenix cookie and session secret | Required |
| `SKOPOS_PUBLIC_URL` | External URL used by browser authentication and realtime connections | `http://localhost:4000` |
| `SKOPOS_PORT` | Host port mapped to the server's container port 4000 | `4000` |
| `SKOPOS_CASE_COLLECT_SECONDS` | Signal collection window in seconds | `5`; integer from `0` to `30` |
| `SKOPOS_IMAGE` | Docker image name | `ghcr.io/skopos-org/skopos`; use `skopos-local` for the source build |
| `SKOPOS_VERSION` | Local image tag and build metadata | Current source version in `compose.yaml` |

`SKOPOS_PUBLIC_URL` must be an HTTP(S) origin, for example
`https://skopos.example.org`. It cannot contain credentials, a path, a query, or a
fragment. Include the port when it is not the scheme's default port. Changing
`SKOPOS_PORT` alone does not change the public URL.

The supplied Compose server listens on HTTP inside the container. When exposing
an HTTPS public URL, configure a reverse proxy to terminate TLS and forward
requests, including WebSocket connections, to port 4000.

Apply changed Compose environment settings by recreating the server:

```sh
docker compose up -d server
```

Keep the credentials key stable for an existing database. Changing signing or
session secrets also affects existing authentication sessions.

## External database and server releases

The server runtime accepts either `DATABASE_URL` or separate `DATABASE_HOST`,
`DATABASE_NAME`, `DATABASE_USER`, and `DATABASE_PASSWORD` values. The separate
form also accepts `DATABASE_PORT`, defaulting to `5432`. `POOL_SIZE` defaults to
`10`; `ECTO_IPV6=true` or `1` enables IPv6 database sockets.

These additional settings are not automatically forwarded by the supplied
Compose services. Use an explicit Compose override or your deployment platform's
environment configuration when connecting an external database.

For an ordinary server release, `PORT` sets its HTTP listener port and
`PHX_SERVER=true` enables the HTTP endpoint. The repository's Docker image sets
these values already. Documentation changes do not require database migrations.
