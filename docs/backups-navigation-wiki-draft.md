# Wiki edit draft: backup and migration navigation

Private publication draft for the existing [Backups and restore](https://github.com/TheBadFella/Pinchflat-NGX/wiki/Backups-and-Restore) and [SQLite to PostgreSQL migration](https://github.com/TheBadFella/Pinchflat-NGX/wiki/SQLite-to-PostgreSQL-migration) guides. Do not publish before the code merges. Check the live wiki text and retain its existing backup, restore, migration and recovery instructions; replace only outdated navigation and affected route references.

## Backups and restore

- Keep the instructions for the current published version: open **Settings > PostgreSQL Backups**.
- Add an explicitly marked upcoming section for this change: on the PostgreSQL image, open **Config > Backups** to set the retention count, create and download a dump, or download a completed dump. On SQLite, this page explains that PostgreSQL backups are unavailable and links to the migration page. Previously generated download URLs under `/settings/backups/<filename>.dump` remain valid; new links use `/backups/<filename>.dump`. The retained backups stay in the persistent configuration volume. Link to the existing restore instructions instead of duplicating them.
- After merge, identify the PR/commit in the upcoming notice. Remove or reconcile the notice only when the change is released.

## SQLite to PostgreSQL migration

- In an explicitly marked upcoming section with the merged PR/commit, note that **Config > PostgreSQL Migration** opens the existing migration status/review page. The SQLite page points to the existing guide and explains that transfer runs from the PostgreSQL image after configuring `DATABASE_URL` and `SQLITE_MIGRATION_SOURCE`; the PostgreSQL page without a pending transfer explains how to configure a source. Keep the existing backup, stopped-instance, file-path and queue-review instructions as the authority.
- Check any old navigation links or section anchors in the existing guide and affected wiki references. Preserve released-version steps until release, then reconcile both guides with the published tag.

File reconciliation changes only the layout and wording of the existing mode descriptions; no workflow or mode contract changed. Check the existing wiki's internal links and release-note deep links when applying these edits. This draft is not a published user guide.
