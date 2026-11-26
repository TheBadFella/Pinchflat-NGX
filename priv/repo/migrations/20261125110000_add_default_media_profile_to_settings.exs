defmodule Pinchflat.Repo.Migrations.AddDefaultMediaProfileToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :default_media_profile_id, references(:media_profiles, on_delete: :nilify_all),
        null: true
    end
  end
end
