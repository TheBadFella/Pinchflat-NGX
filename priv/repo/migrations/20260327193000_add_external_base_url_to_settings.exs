defmodule Pinchflat.Repo.Migrations.AddExternalBaseUrlToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :external_base_url, :string
    end
  end
end
