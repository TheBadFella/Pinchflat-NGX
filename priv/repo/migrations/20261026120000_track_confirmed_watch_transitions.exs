defmodule Pinchflat.Repo.Migrations.TrackConfirmedWatchTransitions do
  use Ecto.Migration

  def up do
    alter table(:media_watches) do
      add :current_upstream_duration_seconds, :integer
      add :confirmed_change_at, :utc_datetime
      add :released_at, :utc_datetime
      add :release_manifest_sha256, :string
    end

    flush()

    execute("""
    UPDATE media_watches
    SET confirmed_change_at = COALESCE(hold_at, updated_at),
        current_upstream_duration_seconds = CASE
          WHEN suspected_kind = 'duration' THEN CAST(suspected_value AS INTEGER)
          ELSE baseline_upstream_duration_seconds END
    WHERE confirmed_state = 'confirmed'
    """)
  end

  def down do
    [[count]] =
      repo().query!("""
      SELECT COUNT(*) FROM media_watches
      WHERE current_upstream_duration_seconds IS NOT NULL OR confirmed_change_at IS NOT NULL
         OR released_at IS NOT NULL OR release_manifest_sha256 IS NOT NULL
      """).rows

    if count > 0,
      do:
        raise(
          "refusing rollback that would discard confirmed watch transitions or release consent"
        )

    alter table(:media_watches) do
      remove :current_upstream_duration_seconds
      remove :confirmed_change_at
      remove :released_at
      remove :release_manifest_sha256
    end
  end
end
