defmodule PinchflatWeb.PostgresMigrationHTML do
  use PinchflatWeb, :html
  embed_templates "postgres_migration_html/*"

  def recovery_guidance(error) do
    case error do
      error when error in ["source_unavailable", "source_read_failed"] ->
        "Check SQLITE_MIGRATION_SOURCE, its config mount and read permissions, then retry. Keep the SQLite instance stopped."

      error when error in ["unsupported_source_version", "unsupported_source_tables", "unsupported_source_columns"] ->
        "Use matching SQLite and PostgreSQL image versions. Upgrade the SQLite installation first, stop it, then retry with its updated database. Do not remove tables or columns to force a transfer."

      error when error in ["source_integrity", "source_foreign_keys", "source_settings", "legacy_review_pending"] ->
        "The SQLite source needs attention. Recover a coherent backup or complete its legacy review on the SQLite installation, then stop it before retrying. Do not delete rows to bypass this check."

      "backup_space_unavailable" ->
        "Free space on the config filesystem for the SQLite snapshot plus 10 MB, check directory permissions, then retry. Keep a separate config and downloads backup."

      "target_not_empty" ->
        "The PostgreSQL target already contains a library. Configure a separate empty application database and restart. Existing target data will not be overwritten."

      "validation_mismatch" ->
        "The copied rows did not match the source after conversion. Keep processing paused and report the table and counts below with your image version. Do not edit the source or delete rows to make validation pass."

      "migration_busy" ->
        "Another transfer owns the migration lock. Wait and refresh the status before retrying. Do not start another instance."

      "interrupted" ->
        "The previous transfer stopped before completion. Once its process has stopped, retry here. The unfinished target copy was rolled back."

      "worker_unavailable" ->
        "The migration worker could not start. Restart the PostgreSQL container and retry here."

      _ ->
        "Check the container log, PostgreSQL availability, server storage and permissions. Keep processing paused and include the error and image version when asking for help. Retry after correcting the cause."
    end
  end
end
