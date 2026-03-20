# Postgres Migration Notes (Draft)

This document captures draft notes created in chat for migrating Pinchflat from SQLite to Postgres, including:

- Appendix A: SQLite-specific patterns to remove (audit list)
- Appendix B: SQLite to Postgres data migration plan
- Appendix C: One-time external migration script (SQLite to Postgres)

These notes are intentionally draft quality and may require updates to match the repo's evolving code.

---

## Appendix A - SQLite-specific patterns to remove (audit list)

This is a targeted audit checklist of patterns that are known to be SQLite-specific (or SQLite-first) and must be removed/replaced for a Postgres-only migration.

> Note: automated search results may be incomplete due to search result caps. Please re-run searches in the GitHub UI to confirm full coverage:
>
> - Repo code search: https://github.com/Mozart409/pinchflat/search?q=fragment%28&type=code
> - Migrations folder: https://github.com/Mozart409/pinchflat/tree/master/priv/repo/migrations

### A.1 `fragment(` usage (SQL fragments)

**Observed in:**

- `lib/pinchflat/media/media_query.ex`
  - Examples include fragments with `regexp_like`, `IFNULL`, `DATETIME`, `DATE('now', ...)`, `MATCH` FTS, `snippet(...)`, and `rank`.
  - URL (representative excerpt):
    - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/lib/pinchflat/media/media_query.ex#L38-L153
    - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/lib/pinchflat/media/media_query.ex#L137-L226

**Implication:** fragments need to be rewritten for Postgres (or removed in favor of Ecto functions) to avoid runtime SQL errors.

---

### A.2 `execute("""` usage in migrations (raw SQL)

**Observed in:**

- `priv/repo/migrations/20260308222828_cleanup_orphaned_tasks.exs`

  - Uses `execute(""" ... """)`:
  - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/priv/repo/migrations/20260308222828_cleanup_orphaned_tasks.exs#L1-L17

- `priv/repo/migrations/20240401170440_re_re_add_source_uniqueness_index.exs`
  - Uses `execute """ ... """` to create/drop an index.
  - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/priv/repo/migrations/20240401170440_re_re_add_source_uniqueness_index.exs#L1-L19

**Implication:** any raw SQL in migrations must be reviewed for SQLite-specific functions/syntax (e.g., `IFNULL`) and rewritten to Postgres-safe SQL.

---

### A.3 `IFNULL` (SQLite) to `COALESCE` (Postgres)

**Observed in:**

- `lib/pinchflat/media/media_query.ex`

  - `IFNULL(retention_period_days, 0)`
  - `IFNULL(redownload_delay_days, 0)`

- `priv/repo/migrations/20240401170440_re_re_add_source_uniqueness_index.exs`
  - `IFNULL(title_filter_regex, '')` inside a unique index expression.

**Implication:** replace `IFNULL(x, y)` with `COALESCE(x, y)` and adjust expression-index syntax for Postgres.

---

### A.4 `DATETIME(` and `DATE('now', ...)` (SQLite date functions)

**Observed in:**

- `lib/pinchflat/media/media_query.ex`
  - `DATETIME(media_downloaded_at, '+' || retention_period_days || ' day') < DATETIME('now')`
  - `DATE('now', '-' || redownload_delay_days || ' day') > DATE(uploaded_at)`
  - `DATE(media_downloaded_at, '-' || redownload_delay_days || ' day') < DATE(uploaded_at)`

**Implication:** convert to Postgres interval arithmetic.

---

### A.5 `regexp_like` + sqlean regex behavior

**Observed in:**

- `lib/pinchflat/media/media_query.ex`

  - `fragment("regexp_like(?, ?)", mi.title, source.title_filter_regex)`

- `config/runtime.exs` loads the sqlean extension

  - `load_extensions: [ ... "sqlean" ... ]`
  - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/config/runtime.exs#L1-L74

- UI help text references sqlean regex docs:
  - `lib/pinchflat_web/controllers/sources/source_html.ex`
    - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/lib/pinchflat_web/controllers/sources/source_html.ex#L3-L93

**Implication:** replace with Postgres regex operators (`~` / `~*`) and account for regex dialect differences.

---

### A.6 SQLite FTS (`MATCH`, `snippet`, `rank`)

**Observed in:**

- `lib/pinchflat/media/media_query.ex`
  - `fragment("media_items_search_index MATCH ?", ...)`
  - `snippet(media_items_search_index, ...)`
  - `order_by: [desc: fragment("rank")]
  - Code comments explicitly mention "SQLite's FTS5".

**Implication:** implement Postgres search (typically `tsvector` + `tsquery`, or `pg_trgm`) and replace FTS table/index strategy.

---

### A.7 Any mention of `SQLite` in docs/comments (behavioral assumptions)

**Observed in:**

- `AGENTS.md` ("Ecto with SQLite")
- `Pinchflat_improvements.md` has a section about SQLite "Database busy" errors
- `lib/pinchflat/media/media.ex` comment: "SQLite doesn't like empty MATCH clauses."
- `priv/repo/migrations/20260308222828_cleanup_orphaned_tasks.exs` comment: SQLite foreign keys disabled
- `README.md` warns about SQLite WAL on network shares

**Implication:** behavior assumptions may no longer apply after Postgres migration.

---

### A.8 `Oban.Engines.Lite` (SQLite-first Oban engine)

**Observed in:**

- `config/config.exs`
  - `config :pinchflat, Oban, engine: Oban.Engines.Lite, repo: Pinchflat.Repo`
  - https://github.com/Mozart409/pinchflat/blob/e699395375d7dc9319f3175bbd8003ff6e0e3857/config/config.exs#L20-L102

**Implication:** remove `Oban.Engines.Lite` for Postgres and ensure Oban migrations/indices align with Postgres.

---

### A.9 `load_extensions` / `sqlean` (SQLite-only)

**Observed in:**

- `config/runtime.exs`
  - `config :pinchflat, Pinchflat.Repo, load_extensions: [...]`

**Implication:** remove or gate behind adapter checks.

---

## Appendix B - SQLite to Postgres data migration plan (Postgres-only target)

This appendix assumes:

- The target is Postgres-only.
- You need to migrate existing user data from the current SQLite DB.

### B.1 Migration strategy choices

#### Strategy 1 - External migration tool (recommended for speed)

Use **pgloader** (or similar) to copy schema+data from SQLite to Postgres, then run any Postgres-only fixes/migrations.

#### Strategy 2 - In-app migrator (Mix task / Release task)

A one-off task that reads from SQLite and writes to Postgres table-by-table, transforming data as needed.

### B.2 Pre-migration: what must change in the app before Postgres can run

- Switch Repo adapter from SQLite to Postgres.
- Remove sqlean `load_extensions`.
- Remove Oban Lite engine.
- Replace SQLite FTS.

### B.3 Cutover plan (high-level)

1. Stop Pinchflat
2. Backup SQLite DB
3. Provision Postgres
4. Create Postgres schema
5. Migrate data
6. Post-migrate fixes (search index rebuild, sequences)
7. Validate
8. Start Pinchflat on Postgres

### B.4 Concrete "pgloader-style" migration procedure (recommended MVP)

- Exclude SQLite-only tables (especially FTS virtual tables)
- Run pgloader
- Verify sequences and constraints

### B.5 Replacing SQLite FTS with Postgres full-text search

Recommended: `tsvector` column + GIN index, query with `@@` and rank with `ts_rank`, and snippet via `ts_headline`.

### B.6 Handling SQLite-specific SQL in queries/fragments

Rewrite fragments (`IFNULL`, datetime math, `regexp_like`, FTS calls).

### B.7 Oban data migration considerations

Recommended: treat `oban_jobs` as recreatable operational state unless you truly need history.

### B.8 Validation checklist

- Row counts
- FK spot-checks
- Smoke flows
- Run tests: `docker compose run --rm phx mix test`

### B.9 Rollback plan

Keep the SQLite backup and avoid deleting the original until validated.

---

## Appendix C - One-time external migration script (SQLite to Postgres)

This appendix provides a **single-run shell script** intended for operators.

### C.1 What the script does

- Stops Pinchflat
- Backs up SQLite DB
- Verifies Postgres connectivity
- Runs `pgloader` to import
- Runs basic sanity checks

### C.2 Prerequisites

- docker
- sqlite3
- pgloader
- psql

### C.3 Script: `scripts/migrate_sqlite_to_postgres.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SQLITE_PATH=""
PG_URL=""
PINCHFLAT_CONTAINER=""
BACKUP_DIR=""
EXCLUDE_TABLES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sqlite) SQLITE_PATH="$2"; shift 2;;
    --pg) PG_URL="$2"; shift 2;;
    --pinchflat-container) PINCHFLAT_CONTAINER="$2"; shift 2;;
    --backup-dir) BACKUP_DIR="$2"; shift 2;;
    --exclude) EXCLUDE_TABLES+=("$2"); shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_cmd docker
need_cmd sqlite3
need_cmd pgloader
need_cmd psql
need_cmd date

if [[ -z "$SQLITE_PATH" || -z "$PG_URL" || -z "$PINCHFLAT_CONTAINER" || -z "$BACKUP_DIR" ]]; then
  echo "Missing required args." >&2
  echo "Required: --sqlite --pg --pinchflat-container --backup-dir" >&2
  exit 1
fi

if [[ ! -f "$SQLITE_PATH" ]]; then
  echo "SQLite DB not found: $SQLITE_PATH" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_PATH="$BACKUP_DIR/pinchflat.db.backup-$STAMP"

echo "==> Stopping Pinchflat container: $PINCHFLAT_CONTAINER"
docker stop "$PINCHFLAT_CONTAINER" >/dev/null || true

echo "==> Backing up SQLite DB"
sqlite3 "$SQLITE_PATH" ".backup '$BACKUP_PATH'"
echo "Backup written to: $BACKUP_PATH"

echo "==> Verifying Postgres is reachable"
psql "$PG_URL" -v ON_ERROR_STOP=1 -c "SELECT version();" >/dev/null

LOAD_FILE="$(mktemp -t pgloader-pinchflat-XXXX.load)"
SQLITE_URI="sqlite:///$SQLITE_PATH"

{
  echo "LOAD DATABASE"
  echo "     FROM $SQLITE_URI"
  echo "     INTO $PG_URL"
  echo ""
  echo " WITH include drop, create tables, create indexes, reset sequences,"
  echo "      batch rows = 5000, prefetch rows = 5000;"
  echo ""
  for t in "${EXCLUDE_TABLES[@]}"; do
    echo "EXCLUDING TABLE NAMES MATCHING ~<$t>~;"
  done
} > "$LOAD_FILE"

echo "==> Running pgloader"
pgloader "$LOAD_FILE"

echo "==> Post-migration sanity checks (row counts sample)"
psql "$PG_URL" -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'sources' AS table, COUNT(*) FROM sources
UNION ALL SELECT 'media_items', COUNT(*) FROM media_items
UNION ALL SELECT 'media_profiles', COUNT(*) FROM media_profiles
UNION ALL SELECT 'settings', COUNT(*) FROM settings;
SQL

echo "==> Done."
echo "Next steps: start Pinchflat configured for Postgres and rebuild search indexes."
```

### C.4 Suggested defaults for `--exclude`

Exclude the SQLite FTS virtual table referenced by queries:

- `media_items_search_index`

Example:

```bash
./scripts/migrate_sqlite_to_postgres.sh \
  --sqlite /srv/pinchflat/config/pinchflat.db \
  --pg "postgresql://pinchflat:pinchflat@127.0.0.1:5432/pinchflat" \
  --pinchflat-container pinchflat \
  --backup-dir /srv/pinchflat/config/backups \
  --exclude "media_items_search_index"
```
