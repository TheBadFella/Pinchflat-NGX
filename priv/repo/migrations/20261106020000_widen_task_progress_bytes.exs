defmodule Pinchflat.Repo.Migrations.WidenTaskProgressBytes do
  use Ecto.Migration

  def up do
    # SQLite INTEGER already stores signed 64-bit byte counters; keep its existing table intact.
    if Pinchflat.Database.postgres?() do
      alter table(:tasks) do
        modify :progress_downloaded_bytes, :bigint
        modify :progress_total_bytes, :bigint
        modify :progress_speed_bytes_per_second, :bigint
      end
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      repo().query!("LOCK TABLE tasks IN ACCESS EXCLUSIVE MODE")

      %{rows: [[count]]} =
        repo().query!(
          "SELECT COUNT(*) FROM tasks WHERE (progress_downloaded_bytes IS NOT NULL AND progress_downloaded_bytes NOT BETWEEN -2147483648 AND 2147483647) OR (progress_total_bytes IS NOT NULL AND progress_total_bytes NOT BETWEEN -2147483648 AND 2147483647) OR (progress_speed_bytes_per_second IS NOT NULL AND progress_speed_bytes_per_second NOT BETWEEN -2147483648 AND 2147483647)"
        )

      if count > 0 do
        raise "cannot narrow task progress byte counters: #{count} row(s) exceed the original integer range"
      end

      alter table(:tasks) do
        modify :progress_downloaded_bytes, :integer
        modify :progress_total_bytes, :integer
        modify :progress_speed_bytes_per_second, :integer
      end
    end
  end
end
