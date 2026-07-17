defmodule Pinchflat.Diagnostics.DatabaseDiagnostics do
  @moduledoc """
  Insight into the SQLite database itself: on-disk size (including the WAL/SHM
  sidecar files), space reclaimable by VACUUM, row counts for key tables, and
  the status of the most recent database maintenance run.

  Powers the "Database" section of the diagnostics page.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task

  # Sorted roughly by how interesting they are on a diagnostics page
  @tracked_tables ~w(media_items sources media_profiles tasks oban_jobs)

  @doc """
  Returns size and page statistics for the database.

  The UI-facing "database size" is the sum of the main file plus the `-wal`
  and `-shm` sidecars, which is why it reads larger than an `ls` of the main
  file alone. `reclaimable_bytes` is the freelist (pages left behind by
  deleted rows) — the space a VACUUM would return to the filesystem.

  Returns map()
  """
  def get_database_stats do
    main_file_bytes = file_size(database_filepath())
    wal_file_bytes = file_size(database_filepath() <> "-wal")
    shm_file_bytes = file_size(database_filepath() <> "-shm")

    %{
      main_file_bytes: main_file_bytes,
      wal_file_bytes: wal_file_bytes,
      shm_file_bytes: shm_file_bytes,
      total_bytes: main_file_bytes + wal_file_bytes + shm_file_bytes,
      page_size: pragma_number("page_size"),
      page_count: pragma_number("page_count"),
      freelist_count: pragma_number("freelist_count"),
      reclaimable_bytes: pragma_number("freelist_count") * pragma_number("page_size"),
      journal_mode: to_string(pragma_value("journal_mode"))
    }
  end

  @doc """
  Returns row counts for the tables that dominate database growth.

  Returns [{table_name :: binary(), count :: non_neg_integer()}]
  """
  def table_row_counts do
    Enum.map(@tracked_tables, fn table ->
      {table, Repo.aggregate(from(t in table), :count)}
    end)
  end

  @doc """
  Counts tasks whose Oban job no longer exists. Should always be zero (the
  foreign key cascades task deletion when jobs are pruned) — a non-zero value
  is a canary for records being left behind.

  Returns non_neg_integer()
  """
  def orphaned_task_count do
    from(t in Task,
      left_join: j in Oban.Job,
      on: t.job_id == j.id,
      where: is_nil(j.id)
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the most recent `DatabaseMaintenanceWorker` job record (in any
  state), or nil if none exists. Used to surface the outcome of both manual
  and scheduled maintenance runs in the UI.

  Returns %Oban.Job{} | nil
  """
  def latest_maintenance_job do
    worker_name = Oban.Worker.to_string(Pinchflat.Diagnostics.DatabaseMaintenanceWorker)

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      order_by: [desc: j.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Returns the full path to the main database file.

  Returns binary()
  """
  def database_filepath do
    Application.get_env(:pinchflat, Pinchflat.Repo)[:database]
  end

  @doc """
  Returns the size of the file at the given path in bytes, or 0 if it
  doesn't exist.

  Returns non_neg_integer()
  """
  def file_size(filepath) do
    case File.stat(filepath) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc """
  Formats a byte count as a human-readable binary-unit string.

  Returns binary()
  """
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  def format_bytes(bytes) when bytes < 1024 * 1024 * 1024, do: "#{Float.round(bytes / 1024 / 1024, 1)} MiB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GiB"

  defp pragma_number(pragma) do
    case pragma_value(pragma) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  # Restricted to a known allowlist since PRAGMA names can't be parameterized
  defp pragma_value(pragma) when pragma in ~w(page_size page_count freelist_count journal_mode) do
    %{rows: [[value]]} = Repo.query!("PRAGMA #{pragma}")

    value
  end
end
