defmodule Pinchflat.Repo.Migrations.AddDownloadSpaceProtectionToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :download_space_protection_enabled, :boolean, default: false, null: false

      add :download_space_protection_threshold_bytes, :bigint,
        default: 10_737_418_240,
        null: false

      add :download_space_protection_blocked, :boolean, default: false, null: false
      add :download_space_protection_blocked_reason, :string
      add :download_space_protection_blocked_location, :string
      add :download_space_protection_free_bytes, :bigint
      add :download_space_protection_blocked_at, :utc_datetime
      add :download_space_protection_alerted_at, :utc_datetime
    end
  end
end
