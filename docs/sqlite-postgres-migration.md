# Move an existing SQLite library to PostgreSQL

SQLite remains supported. Switching images alone does not transfer your library. This optional flow copies data only after you click **Migrate to Postgres** in the configured PostgreSQL build.

## Prepare both databases

1. Update your SQLite installation to the matching NGX release first. The importer requires the current source schema; it refuses older, newer or unrecognized tables/columns. Complete any legacy migration review before planning this separate database move.
2. Stop the SQLite container. Back up config and downloads together while stopped, retaining the SQLite database and any WAL/SHM companions. Keep that container stopped throughout transfer and review.
3. Configure the PostgreSQL image and a reachable PostgreSQL server. Keep the same config and downloads mounts and container paths. Use an empty target application database; existing profiles, sources, media, jobs or metadata are refused. Its freshly seeded default settings will be replaced by your retained SQLite settings.
4. Set `SQLITE_MIGRATION_SOURCE` to the retained SQLite database path in the container, usually `/config/db/pinchflat.db` (some older installations use `/config/pinchflat.db`). Keep it configured through review. Start the PostgreSQL container. The normal application schema migrations still run before the transfer screen opens.

For example, add these settings to your existing PostgreSQL service:

```yaml
environment:
  DATABASE_URL: ecto://pinchflat:your-password@postgres/pinchflat
  SQLITE_MIGRATION_SOURCE: /config/db/pinchflat.db
  POSTGRES_BACKUP_PATH: /config/extras/backups
volumes:
  - ./config:/config
  - ./downloads:/downloads
```

Use your actual connection settings and keep them private. The database adapter is compiled into the PostgreSQL image; setting a variable on the SQLite image does not change its adapter. Diagnostics shows the active database type.

## Transfer and review

The PostgreSQL instance holds background processing and redirects library routes to `/postgres_migration`. Internal API calls return 503 while held. This protects the empty target and the copied library from downloads, retention and reconciliation before review.

Confirm that the old instance is stopped and coherent backups exist, then click **Migrate to Postgres**. The server:

- Opens the source read-only and checks its schema, integrity and relationships.
- Checks capacity for a new SQLite snapshot, creates a unique backup with `VACUUM INTO`, and retains it with restricted permissions. This includes committed WAL data rather than copying a live database file alone.
- Locks the empty target, copies application tables in dependency order and preserves IDs, UUIDs, metadata, preferences, timestamps, file paths and source pause choices.
- Converts SQLite booleans, JSON/arrays and timestamps to PostgreSQL types. PostgreSQL search triggers rebuild search vectors; explicit IDs are followed by sequence resets.
- Retains completed job history. Interrupted executing jobs become retryable, lose old node ownership and regain one attempt. No media files are moved or downloaded by the transfer.
- Compares every copied field and row count before committing the library and its review record together.

Refresh the page to see the outcome. Review table counts, downloaded-item count, recorded bytes and missing media paths. Recorded bytes come from the database; they are not a fresh filesystem measurement. Missing paths remain recorded. Verify the downloads mount before resuming anything.

Runtime queue pauses are not stored in the old SQLite database. The review screen therefore asks which queues should stay paused and defaults to keeping all of them paused. Source-level pause choices are copied. Choose the queues you want to keep paused, confirm the library, and **restart the PostgreSQL container** to apply those choices and restore normal startup tasks/plugins. Confirmation does not resume work in the current process.

## Errors and retry

A failed copy rolls back the target application rows. The original database and unique snapshots remain available. Keep the old container stopped and fix the reported condition before retrying:

| Result                                                                                    | Action                                                                                                                                            |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_unavailable` / `source_read_failed`                                               | Check the configured path, mounted config directory, permissions and SQLite WAL access. The importer will not create a new empty source database. |
| `unsupported_source_version` / `unsupported_source_tables` / `unsupported_source_columns` | Use matching current NGX images. Do not delete unexpected tables or columns to force acceptance.                                                  |
| `source_integrity` / `source_foreign_keys` / `source_settings`                            | Check and recover the SQLite installation or its coherent backup before trying again.                                                             |
| `backup_space_unavailable`                                                                | Ensure the backup filesystem has room for the source snapshot plus 10 MB and supports the capacity check.                                         |
| `target_not_empty`                                                                        | Use a separate empty application database. The importer will not merge or overwrite an existing library.                                          |
| `validation_mismatch` / `unsupported_column_type`                                         | Keep the backup and report the unsupported case. Do not resume jobs.                                                                              |
| `migration_busy`                                                                          | Another transfer owns the database lock. Wait and refresh; do not start a second instance to bypass the hold.                                     |
| `interrupted`                                                                             | After the previous process is stopped, restart this container and retry the rolled-back transfer.                                                 |
| `transfer_failed`                                                                         | Check database availability, server storage, permissions and supported types. The exported status omits credentials and SQL parameter values.     |

Backup filesystem capacity is checked locally. Capacity on a remote PostgreSQL server must be monitored by its administrator. The transfer fails transactionally if the server rejects writes; it does not inspect the remote server's disk.

## Rollback limits

Before normal PostgreSQL processing resumes, you can stop the new container and restore the coherent config/download backup to a separate directory, then start the matching SQLite image with that restored pair. Keep the migrated state separately for investigation.

After new work runs in PostgreSQL, the retained SQLite snapshot does not contain those changes. Switching back is not a reverse synchronization; restore a coherent database and filesystem pair that represents the same point in time. Never run both instances against the same downloads mount.

Physical ARM/NAS execution and merging this feature with independently developed migration bundles require separate release acceptance. Keep this draft local until those applicable integration checks are complete.
