defmodule Pinchflat.Repo.Migrations.AddDownloadErrorStateToMediaItems do
  use Ecto.Migration

  def up do
    alter table(:media_items) do
      add :error_type, :string
      add :download_prevented_reason, :string
    end

    # Existing prevention flags have no reliable provenance. Treating them as
    # manual preserves the existing blocked behavior without inventing a policy
    # or error cause from historical data.
    execute "UPDATE media_items SET download_prevented_reason = 'manual' WHERE prevent_download = 1"
  end

  def down do
    alter table(:media_items) do
      remove :error_type
      remove :download_prevented_reason
    end
  end
end
