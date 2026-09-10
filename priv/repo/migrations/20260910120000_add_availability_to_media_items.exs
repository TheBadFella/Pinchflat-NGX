defmodule Pinchflat.Repo.Migrations.AddAvailabilityToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :availability, :string
    end
  end
end
