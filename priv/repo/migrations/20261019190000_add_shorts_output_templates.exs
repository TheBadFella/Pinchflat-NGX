defmodule Pinchflat.Repo.Migrations.AddShortsOutputTemplates do
  use Ecto.Migration

  def change do
    alter table(:media_profiles) do
      add :output_path_template_shorts, :text
    end

    alter table(:sources) do
      add :output_path_template_shorts_override, :text
    end
  end
end
