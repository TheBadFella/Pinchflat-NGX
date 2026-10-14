# Backing up config before migration

_Optional._ You do not need this page to [migrate from Pinchflat](legacy-pinchflat-migration.md). Use it only if you want a rollback copy of **config** before changing the Docker image.

Take a **config** backup **before** changing the Docker image to Pinchflat-NGX. Keep it somewhere NGX will not touch (another disk, NAS share, or cloud storage). You need it to roll back the database and settings if anything goes wrong.

This page covers only **`/config`** (typically `./config` on the host). Migration does not move, rewrite, or delete files under **`/downloads`**. Leave that bind mount unchanged.

| What this page covers              | Default container path | Typical host bind |
| ---------------------------------- | ---------------------- | ----------------- |
| Database, settings, logs, metadata | `/config`              | `./config`        |

SQLite normally lives at `/config/db/pinchflat.db`. With WAL mode you may also see `pinchflat.db-wal` and `pinchflat.db-shm` in the same folder. **Back up the whole `config` directory**, not only `pinchflat.db`, and **stop the container first** so the database files are consistent.

## 1. Stop Pinchflat

From the directory that contains your `compose.yaml`:

```bash
docker compose stop
```

Confirm the container is not running (`docker compose ps`).

## 2. Archive config (recommended)

Run these on the **host**, from the same directory as your Compose file. These examples assume a bind-mounted `./config` directory; replace that path if yours differs. Use an account that can read all config files. Keep the container stopped until the archive succeeds.

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/pinchflat-backups/pre-ngx-${STAMP}"
mkdir -p "${BACKUP_DIR}"

tar -czf "${BACKUP_DIR}/config.tar.gz" ./config
# Continue only if tar succeeds. Check the archive, not just the live directory:
tar -tzf "${BACKUP_DIR}/config.tar.gz"
```

**Windows (PowerShell)**. From your Compose folder:

```powershell
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:USERPROFILE "pinchflat-backups\pre-ngx-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
tar -czf (Join-Path $backupDir "config.tar.gz") -C . config
if ($LASTEXITCODE -ne 0) { throw "Config backup failed; keep Pinchflat stopped." }
tar -tzf (Join-Path $backupDir "config.tar.gz")
if ($LASTEXITCODE -ne 0) { throw "Config archive cannot be read." }
```

The listing should contain `config/db/pinchflat.db` (or `config/pinchflat.db` for an older layout). Any WAL/SHM files still present are included because the entire directory is archived. Config can contain credentials; store the archive privately.

## Restore config from this backup (rollback)

If you need to return to **upstream Pinchflat** after a failed migration attempt:

1. Stop Pinchflat-NGX: `docker compose stop`
2. Set `BACKUP_DIR` to the directory containing your **pre-ngx** archive. Restore into a temporary directory and verify that the database exists before replacing the current config:

```bash
# Bash, from your Compose directory. BACKUP_DIR must point to your own archive.
(
  set -eu
  test -d ./config
  RESTORE_DIR="$(mktemp -d ./config-restore.XXXXXX)"
  tar -xzf "${BACKUP_DIR:?Set BACKUP_DIR first}/config.tar.gz" -C "${RESTORE_DIR}"
  test -f "${RESTORE_DIR}/config/db/pinchflat.db" || test -f "${RESTORE_DIR}/config/pinchflat.db"
  test ! -L "${RESTORE_DIR}/config"
  # Reserve a unique location and retain the current config for recovery.
  SAVED_DIR="$(mktemp -d ./config-before-rollback.XXXXXX)"
  mv ./config "${SAVED_DIR}/config"
  mv "${RESTORE_DIR}/config" ./config
)
```

**Windows (PowerShell):**

```powershell
# $backupDir must point to your pre-ngx archive. Keep the container stopped.
$restoreDir = Join-Path (Get-Location) ("config-restore-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $restoreDir -ErrorAction Stop | Out-Null
tar -xzf (Join-Path $backupDir "config.tar.gz") -C $restoreDir
if ($LASTEXITCODE -ne 0) { throw "Config extraction failed; current config unchanged." }
$restoredConfig = Join-Path $restoreDir "config"
if (!(Test-Path (Join-Path $restoredConfig "db/pinchflat.db") -PathType Leaf) -and
    !(Test-Path (Join-Path $restoredConfig "pinchflat.db") -PathType Leaf)) {
    throw "No database in restored config; current config unchanged."
}
$savedConfig = Join-Path (Get-Location) ("config-before-rollback-" + [guid]::NewGuid().ToString("N"))
Move-Item -LiteralPath ./config -Destination $savedConfig -ErrorAction Stop
Move-Item -LiteralPath $restoredConfig -Destination ./config -ErrorAction Stop
```

3. If a move fails, keep the container stopped. The old config remains in the `config-before-rollback...` location; do not start with a missing or partial config.
4. Point Compose back at the **upstream Pinchflat image**, keep the same mounts, and start: `docker compose pull` followed by `docker compose up -d`.

Do **not** start upstream Pinchflat against a database that Pinchflat-NGX has already migrated unless you know that schema is compatible with your upstream version. When in doubt, restore the **pre-ngx** config backup only.

## Already on Pinchflat-NGX with PostgreSQL?

This page is for **SQLite** libraries moving from upstream Pinchflat. If you already run the PostgreSQL image, use **Settings → PostgreSQL Backups** and the [Backups and restore](https://github.com/TheBadFella/pinchflat-ngx/wiki/Backups-and-Restore) guide for database dumps.

Return to [Migrating from Pinchflat](legacy-pinchflat-migration.md), [Installation](https://github.com/TheBadFella/pinchflat-ngx/wiki/Installation), or [Upgrading and rollback](https://github.com/TheBadFella/pinchflat-ngx/wiki/Upgrading-and-Rollback).
