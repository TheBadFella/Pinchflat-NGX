defmodule Pinchflat.Repo.Migrations.UpdateObanForPostgres do
  use Ecto.Migration

  def up do
    if Pinchflat.Database.postgres?(), do: Oban.Migration.up(version: 14)
  end

  def down do
    if Pinchflat.Database.postgres?(), do: Oban.Migration.down(version: 12)
  end
end
