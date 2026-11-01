defmodule Pinchflat.Repo.Migrations.AddErrorCountToMediaWatches do
  use Ecto.Migration

  def change do
    alter table(:media_watches) do
      add :error_count, :integer, null: false, default: 0
    end
  end
end
