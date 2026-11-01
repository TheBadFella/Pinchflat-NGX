defmodule Pinchflat.Repo.Migrations.WidenMediaSizeBytes do
  use Ecto.Migration

  def up do
    # SQLite INTEGER already stores signed 64-bit sizes; keep its existing table intact.
    if Pinchflat.Database.postgres?() do
      alter table(:media_items) do
        modify :media_size_bytes, :bigint
      end
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      repo().query!("LOCK TABLE media_items IN ACCESS EXCLUSIVE MODE")

      %{rows: [[count]]} =
        repo().query!(
          "SELECT COUNT(*) FROM media_items WHERE media_size_bytes NOT BETWEEN -2147483648 AND 2147483647"
        )

      if count > 0 do
        raise "cannot narrow media sizes: #{count} row(s) exceed the original integer range"
      end

      alter table(:media_items) do
        modify :media_size_bytes, :integer
      end
    end
  end
end
