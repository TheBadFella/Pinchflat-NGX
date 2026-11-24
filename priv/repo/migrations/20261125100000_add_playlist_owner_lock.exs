defmodule Pinchflat.Repo.Migrations.AddPlaylistOwnerLock do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :owner_channel_id, :string
      add :only_owner_uploads, :boolean, default: false, null: false
    end

    alter table(:media_items) do
      add :channel_id, :string
    end
  end
end
