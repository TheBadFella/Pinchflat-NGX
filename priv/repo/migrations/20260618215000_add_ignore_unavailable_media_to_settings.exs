defmodule Pinchflat.Repo.Migrations.AddIgnoreUnavailableMediaToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :ignore_unavailable_media, :boolean, default: false
    end
  end
end
