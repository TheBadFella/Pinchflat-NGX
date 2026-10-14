defmodule Pinchflat.Repo.Migrations.WidenSourceDescription do
  use Ecto.Migration

  def up do
    if Pinchflat.Database.postgres?() do
      alter table(:sources) do
        modify :description, :text
      end
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      # Keep writes from changing a checked value before the column is narrowed.
      repo().query!("LOCK TABLE sources IN ACCESS EXCLUSIVE MODE")

      %{rows: [[count]]} =
        repo().query!("SELECT COUNT(*) FROM sources WHERE char_length(description) > 255")

      if count > 0 do
        raise "cannot narrow source descriptions: #{count} row(s) exceed the original varchar(255) limit"
      end

      alter table(:sources) do
        modify :description, :string
      end
    end
  end
end
