defmodule Pinchflat.Repo.Migrations.AddDownloadSubdirectoryToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :download_subdirectory, :text
    end
  end
end
