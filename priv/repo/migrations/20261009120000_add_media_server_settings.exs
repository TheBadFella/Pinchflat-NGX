defmodule Pinchflat.Repo.Migrations.AddMediaServerSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Plex Media Server
      add :plex_enabled, :boolean, default: false, null: false
      add :plex_url, :string
      add :plex_token, :string
      add :plex_library_section_id, :string, default: "all"

      # Jellyfin
      add :jellyfin_enabled, :boolean, default: false, null: false
      add :jellyfin_url, :string
      add :jellyfin_api_key, :string
      add :jellyfin_library_id, :string

      # Emby
      add :emby_enabled, :boolean, default: false, null: false
      add :emby_url, :string
      add :emby_api_key, :string
      add :emby_confirm_full_scan, :boolean, default: false, null: false
    end
  end
end
