# Installation

This guide runs Skopos from source using the repository's Dockerfile and
`compose.yaml`. You need Git, Docker with the Compose plugin, and OpenSSL. Docker
must have network access to download the build images and dependencies. The
Dockerfile supplies the Elixir, Erlang, Node, and Rust build tools.

## Get the source

```sh
git clone https://github.com/skopos-org/skopos.git
cd skopos
```

## Configure the installation

Create a private `.env` file at the repository root. Run the following once for a
new installation:

```sh
umask 077
cat > .env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SKOPOS_CREDENTIALS_KEY=$(openssl rand -base64 32)
SKOPOS_TOKEN_SIGNING_SECRET=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)
SKOPOS_IMAGE=skopos-local
SKOPOS_PUBLIC_URL=http://localhost:4000
SKOPOS_PORT=4000
EOF
```

Retain this file alongside your database backups. In particular, the credentials
key is needed to decrypt saved Provider credentials. Re-running this command
would replace the installation's existing secrets.

The local image name identifies the image built by Compose. For access
through another hostname or a reverse proxy, set `SKOPOS_PUBLIC_URL` to the
external HTTP(S) origin before starting the server. See
[Configuration](configuration.md).

## Build and start

```sh
docker compose up --build -d
docker compose ps --all
docker compose logs migrate server
```

Compose starts PostgreSQL, runs database migrations, and then starts the server.
The `migrate` service is expected to exit successfully; `server` should remain
running. PostgreSQL data lives in the named `database` volume.

Open <http://localhost:4000> for the local configuration above and follow
[First-time setup](first-steps.md).

## Stop and start

```sh
docker compose stop
docker compose start database server
```

Stopping services preserves the database volume.

## Update an installation

Back up the database and retain the installation's secrets before updating. Check
out the source revision you intend to deploy, then rebuild and start the services:

```sh
docker compose up --build -d
docker compose ps --all
docker compose logs migrate server
```

Confirm that migrations completed successfully, then sign in and check the
configured connections and recent Cases. See [Operations](operations.md) for
backup and recovery instructions.
