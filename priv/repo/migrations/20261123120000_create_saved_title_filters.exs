defmodule Pinchflat.Repo.Migrations.CreateSavedTitleFilters do
  use Ecto.Migration

  def change do
    create table(:saved_title_filters) do
      add :name, :text, null: false
      add :regex, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:saved_title_filters, [:name])
  end
end
