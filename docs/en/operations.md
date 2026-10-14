# Operations

## Follow an incident

Open **Cases** to find the incident and inspect its timeline, observations,
proposals, operations, verification attempts, AI usage, and reports. An accepted
request is not necessarily a completed operation. Use its persisted status to
follow progress; the [CLI](cli.md) also provides `wait` commands.

In Ask mode, review the exact proposed effect and make the human decision through
the Case. An applied effect and a verified outcome are separate results. If an
operation is `unknown` or `partial`, inspect the recorded evidence and current
Target state before attempting the effect again. A lost response can leave the
remote change's outcome uncertain.

When a Case needs attention, inspect its reason and evidence. Correct the relevant
connection, role assignment, scope, or limit before deciding to resume. Retain
Case and operation identifiers when requesting help.

## Inspect the server

```sh
docker compose ps --all
docker compose logs --tail 200 server
docker compose logs --tail 200 migrate
docker compose logs --tail 200 database
```

If startup fails, check the migration result, PostgreSQL health, required secrets,
and the public URL. If an AI or Target operation fails, inspect its Provider check
and Case evidence as well as server logs.

## Back up the database

Create a PostgreSQL archive from the bundled database:

```sh
umask 077
docker compose exec -T database pg_dump -U skopos -d skopos -Fc > skopos.dump
```

Store the archive and the installation's `.env` file in protected backup storage.
The database contains saved configuration and incident history; the original
credentials encryption key is needed to use its encrypted credentials.

## Restore a backup

Restore into an installation using the original secrets and a compatible source
revision. The following replaces existing database objects with the archive's
contents, so preserve any database you need before proceeding:

```sh
docker compose stop server
docker compose up -d database
docker compose exec -T database pg_restore --clean --if-exists --exit-on-error \
  -U skopos -d skopos < skopos.dump
docker compose up --build -d
```

After startup, sign in and inspect configuration and recent Cases. A database
restore does not reverse changes already made to remote infrastructure. Restored
queued work may resume, so coordinate Target access and authority before bringing
the server back into service.
