# Installation

Run the Skopos server with Docker Compose and its release container image.
Choose Web or CLI to operate Skopos. Install the CLI only if you will use it.

## Install the server

You need Docker with the Compose plugin, curl, and OpenSSL.

Choose a version from [GitHub Releases](https://github.com/skopos-org/skopos/releases).
Replace `RELEASE_VERSION` below with the version number without the leading `v`.

```sh
mkdir skopos
cd skopos
export SKOPOS_VERSION=RELEASE_VERSION
curl --fail --location \
  "https://raw.githubusercontent.com/skopos-org/skopos/v${SKOPOS_VERSION}/compose.yaml" \
  --output compose.yaml
```

Create the installation settings once. Set `SKOPOS_PUBLIC_URL` to the URL
operators will use; the example below uses the local server.

```sh
umask 077
cat > .env <<EOF
SKOPOS_VERSION=${SKOPOS_VERSION}
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SKOPOS_CREDENTIALS_KEY=$(openssl rand -base64 32)
SKOPOS_TOKEN_SIGNING_SECRET=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)
SKOPOS_PUBLIC_URL=http://localhost:4000
SKOPOS_PORT=4000
EOF
docker compose pull
docker compose up --no-build -d
docker compose ps --all
```

Check that `migrate` exited with code 0 and `server` is running.
Open the configured public URL and continue with [First-time setup](first-steps.md).

See [Configuration](configuration.md) for HTTPS, ports, and other settings.
Keep the existing secrets when changing or updating an installation.

## Install the CLI

Download the executable for your computer and `SHA256SUMS` from the same release.

| Platform | Release asset |
| --- | --- |
| Linux x86-64 | `skopos-VERSION-linux_x86_64` |
| Linux ARM64 | `skopos-VERSION-linux_aarch64` |
| macOS Intel | `skopos-VERSION-macos_x86_64` |
| macOS Apple Silicon | `skopos-VERSION-macos_aarch64` |
| Windows x86-64 | `skopos-VERSION-windows_x86_64.exe` |

Verify the download against `SHA256SUMS`. On Linux and macOS, give the executable
execute permission. Rename it to `skopos` (`skopos.exe` on Windows) and place it
in a directory on your `PATH`.

```sh
skopos --version
skopos --help
```

Continue with the [CLI setup path](first-steps.md#cli).

## Update the server

Read the selected release's notes and download its matching `compose.yaml`.
Change `SKOPOS_VERSION` in the existing `.env` to that release's version, then run:

```sh
docker compose pull
docker compose up --no-build -d
docker compose ps --all
```

Confirm that `migrate` exited with code 0 and `server` is running.
