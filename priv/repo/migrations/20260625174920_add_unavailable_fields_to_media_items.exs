defmodule Pinchflat.Repo.Migrations.AddUnavailableFieldsToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :unavailable_at, :utc_datetime
      add :unavailable_reason, :string
    end
  end
end
