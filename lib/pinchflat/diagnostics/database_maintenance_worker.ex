defmodule Pinchflat.Diagnostics.DatabaseMaintenanceWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    # Dedupe on worker alone (not args) so a manual run and a scheduled run
    # can't be queued alongside each other
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :queue]],
    max_attempts: 3,
    tags: ["local_data", "maintenance"]

  import Ecto.Query, warn: false

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Diagnostics.DatabaseDiagnostics
  alias Pinchflat.Diagnostics.QueueDiagnostics

  # VACUUM rebuilds the database into a temporary copy before swapping it in,
  # so it can briefly need as much free space as the database itself. The
  # margin keeps the disk from being filled to the brim even if the estimate
  # is exact.
  @disk_space_margin_bytes 64 * 1024 * 1024
  @vacuum_timeout :timer.minutes(30)

  @doc """
  Enqueues a manual database maintenance job (the Compact Now button).
  Manual runs execute regardless of the `database_maintenance_enabled`
  setting — pressing the button is its own consent. Uniqueness ensures a
  manual kickoff and the scheduled run can't stack up or run concurrently.

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff do
    Oban.insert(new(%{"manual" => true}))
  end

  @doc """
  Compacts the database: truncates the WAL sidecar, then VACUUMs to return
  freelist pages to the filesystem and refreshes query-planner statistics.

  VACUUM holds the write lock for its whole run — minutes on weak hardware
  with a large database — so this reserves a quiet window first: it pauses
  all job queues, waits (indefinitely — a slow indexing run can take hours)
  for other executing jobs to finish, vacuums, then resumes the queues. The
  queues are resumed even if the VACUUM fails, and a pause can't outlive a
  crash since queue pause state doesn't survive a restart.

  The VACUUM only runs if the filesystem has enough headroom for the
  temporary database copy it builds; otherwise the job fails with a
  descriptive error so it surfaces in the Failed Jobs section of the
  diagnostics page. The WAL truncation always runs — it only ever shrinks
  the files on disk.

  Scheduled (cron) runs only proceed when the user has opted in via the
  `database_maintenance_enabled` setting; manual runs always proceed. A
  skipped scheduled run cancels with a reason so the diagnostics card shows
  why nothing happened rather than silently doing nothing.

  Returns :ok | {:cancel, binary()} | {:error, binary()}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"manual" => true}, id: job_id}), do: run_maintenance(job_id)

  def perform(%Oban.Job{id: job_id}) do
    if Settings.get!(:database_maintenance_enabled) do
      run_maintenance(job_id)
    else
      {:cancel, "Scheduled compaction is turned off — use its tile in the Database section to turn it on"}
    end
  end

  defp run_maintenance(job_id) do
    size_before = DatabaseDiagnostics.get_database_stats().total_bytes

    truncate_wal()

    result =
      with_paused_queues(fn ->
        wait_for_other_running_jobs(job_id)

        # Checked inside the reserved window (rather than up front) since free
        # space can change materially while waiting for jobs to finish
        case check_disk_space() do
          :ok -> run_vacuum()
          error -> error
        end
      end)

    case result do
      :ok ->
        record_reclaimed_bytes(job_id, size_before)

        :ok

      {:error, message} ->
        Logger.warning("Skipping database VACUUM: #{message}")

        {:error, message}
    end
  end

  # Pausing stops queues from starting new jobs but lets executing ones run to
  # completion. Resuming in `after` covers vacuum failures; a crashed node
  # resets pause state on its own since it's held in memory, not the database.
  defp with_paused_queues(fun) do
    queues = QueueDiagnostics.queue_names()

    Enum.each(queues, &Oban.pause_queue(queue: &1))

    try do
      fun.()
    after
      Enum.each(queues, &Oban.resume_queue(queue: &1))
    end
  end

  defp wait_for_other_running_jobs(job_id) do
    if other_jobs_running?(job_id) do
      Logger.info("Database maintenance is waiting for running jobs to finish before vacuuming")
      Process.sleep(Application.get_env(:pinchflat, :db_maintenance_poll_interval))
      wait_for_other_running_jobs(job_id)
    else
      :ok
    end
  end

  # The job ID is nil when run via `Oban.Testing.perform_job/2`
  defp other_jobs_running?(job_id) do
    from(j in Oban.Job, where: j.state == "executing")
    |> then(fn query -> if job_id, do: where(query, [j], j.id != ^job_id), else: query end)
    |> Repo.aggregate(:count)
    |> Kernel.>(0)
  end

  # Flushes the WAL into the main database file and truncates it to zero
  # length. Safe to run unconditionally — it needs no extra disk space. A
  # failed checkpoint (eg: the database is briefly locked) isn't fatal;
  # VACUUM checkpoints on its own anyway.
  defp truncate_wal do
    case Repo.query("PRAGMA wal_checkpoint(TRUNCATE)") do
      {:ok, _result} -> :ok
      {:error, error} -> Logger.warning("WAL checkpoint failed: #{inspect(error)}")
    end
  end

  defp run_vacuum do
    Repo.query!("VACUUM", [], timeout: @vacuum_timeout)
    # Refreshes the query planner's statistics — cheap after a full rebuild
    Repo.query!("PRAGMA optimize")
    # In WAL mode the VACUUM commits the rebuilt database through the WAL,
    # which can balloon to the size of the database itself. Checkpoint and
    # truncate it again so the on-disk footprint shrinks immediately and the
    # reclaimed-bytes measurement isn't distorted by a fat WAL.
    truncate_wal()

    :ok
  end

  # VACUUM builds its temporary copy in SQLite's temp directory and journals
  # in the database directory, so both filesystems need headroom for a full
  # copy of the database.
  defp check_disk_space do
    required_bytes = DatabaseDiagnostics.file_size(DatabaseDiagnostics.database_filepath()) + @disk_space_margin_bytes
    directories = Enum.uniq([Path.dirname(DatabaseDiagnostics.database_filepath()), System.tmp_dir!()])

    Enum.reduce_while(directories, :ok, fn directory, :ok ->
      case disk_space_checker().available_bytes(directory) do
        {:ok, available} when available >= required_bytes ->
          {:cont, :ok}

        {:ok, available} ->
          {:halt,
           {:error,
            "Not enough free disk space to safely VACUUM: " <>
              "#{DatabaseDiagnostics.format_bytes(required_bytes)} needed in #{directory} " <>
              "but only #{DatabaseDiagnostics.format_bytes(available)} is available"}}

        :error ->
          {:halt, {:error, "Could not determine free disk space for #{directory} — refusing to VACUUM"}}
      end
    end)
  end

  # Stores the space savings on the job record so the diagnostics page can
  # report the outcome of the run. The job ID is nil when run via
  # `Oban.Testing.perform_job/2`, which never persists the job.
  defp record_reclaimed_bytes(nil, _size_before), do: :ok

  defp record_reclaimed_bytes(job_id, size_before) do
    size_after = DatabaseDiagnostics.get_database_stats().total_bytes
    reclaimed = max(size_before - size_after, 0)

    from(j in Oban.Job, where: j.id == ^job_id)
    |> Repo.update_all(set: [meta: %{"reclaimed_bytes" => reclaimed}])
  end

  defp disk_space_checker do
    Application.get_env(:pinchflat, :disk_space_checker, Pinchflat.Diagnostics.DiskSpaceChecker)
  end
end
