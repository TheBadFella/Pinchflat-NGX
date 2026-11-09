defmodule Pinchflat.Repo.Migrations.CreateMediaItemOptionHandoffs do
  use Ecto.Migration

  def change do
    create table(:media_item_option_handoffs) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :media_id, :string, null: false
      add :contents, :text, null: false
      add :generation, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_item_option_handoffs, [:source_id])
    create index(:media_item_option_handoffs, [:media_id])
  end
end
