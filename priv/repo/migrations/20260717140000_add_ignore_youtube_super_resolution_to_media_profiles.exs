defmodule Pinchflat.Repo.Migrations.AddIgnoreYoutubeSuperResolutionToMediaProfiles do
  use Ecto.Migration

  def change do
    alter table(:media_profiles) do
      add :ignore_youtube_super_resolution, :boolean, default: false, null: false
    end
  end
end
