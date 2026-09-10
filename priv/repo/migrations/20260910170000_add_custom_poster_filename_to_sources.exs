defmodule Pinchflat.Repo.Migrations.AddCustomPosterFilenameToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :custom_poster_filename, :string
    end
  end
end
