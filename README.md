# postgres-image-with-backup-agent

A tiny **Dart HTTP daemon embedded into a PostgreSQL Docker image**.
It triggers `pg_dump` on demand and writes dumps to a **mounted
directory**.

This image is intended to be used on a **private Docker network** and
called **only from your backend** (never exposed publicly).

## What it provides

- `POST /backup?reason=daily|weekly|monthly|adhoc`
- `GET /health`
- **Bearer token** auth
- Count-based retention for `daily|weekly|monthly`
- Single-run lock with stale detection
- Safe file naming 

> ⚠️ Security: do **not** expose this service publicly.
> Keep it on a private network and require a strong token.

---

## Works great with `serverpod_housekeeping`

If you run a Serverpod backend, you can schedule backups (daily/weekly/monthly) and optionally
trim Serverpod internal log tables using **serverpod_housekeeping**.

- `serverpod_housekeeping` triggers this image via `POST /backup?...`
- Jobs are scheduled in **UTC** using Serverpod FutureCalls
- You can run cleanup logs before backup

See: `serverpod_housekeeping` → https://github.com/Alexqwesa/serverpod_housekeeping

---

## HOWTO use

This repo publishes prebuilt images for:

- `ghcr.io/alexqwesa/postgres-image-with-backup-agent:16.3`
- `ghcr.io/alexqwesa/postgres-image-with-backup-agent:pgvector-pg16`

If you need a different Postgres base image or version, **build your own image**
from this repo by changing the base image in `Dockerfile` or by overriding the
`BASE_IMAGE` build arg.

### .env.example (required)

Copy `.env.example` and set at least:

- `BACKUP_AGENT_TOKEN` (for security in real deployments)
- your database credentials, or set `ALLOW_ANY_DB=true` (to pass them via http header)
- (optional) change `BACKUP_TO_DIR`, retention, timeouts...

Put your real env file in `secret/.env` and keep it out of git!

### Option A — Use a prebuilt image

For plain Postgres 16.3:

1) In your `docker-compose.yml`, replace your Postgres image with:

```yaml
services:
  postgres:
    image: ghcr.io/alexqwesa/postgres-image-with-backup-agent:16.3

    env_file:
      - .env.example
      - secret/.env  # your real secrets

    environment:
      BACKUP_AGENT_PORT: 1804
      BACKUP_TO_DIR: /backups
      BACKUP_KEEP_DAILY: 30
      BACKUP_KEEP_WEEKLY: 12
      BACKUP_KEEP_MONTHLY: 12
    volumes:
      - ./backups:/backups
```

For `pgvector/pgvector:pg16`, use:

```yaml
services:
  postgres:
    image: ghcr.io/alexqwesa/postgres-image-with-backup-agent:pgvector-pg16
```

### Option B — Build your own image for Postgres
```bash
git clone https://github.com/Alexqwesa/postgres-image-with-backup-agent.git
cd postgres-image-with-backup-agent
# override the upstream image if you want a different postgres or pgvector base
docker build --build-arg BASE_IMAGE=postgres:17 -t my-postgres-with-backup-agent .
# or:
docker build --build-arg BASE_IMAGE=pgvector/pgvector:pg16 -t my-pgvector-with-backup-agent .
```
