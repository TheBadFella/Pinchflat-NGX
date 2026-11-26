defmodule Pinchflat.Repo.Migrations.AddTranslatedTitles do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :title_language, :string, null: true
    end

    alter table(:media_items) do
      add :translated_title, :string, null: true
    end
  end
end
