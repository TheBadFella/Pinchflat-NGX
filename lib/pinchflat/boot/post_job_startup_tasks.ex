defmodule Pinchflat.Boot.PostJobStartupTasks do
  @moduledoc """
  This module is responsible for running startup tasks on app boot
  AFTER the job runner has initialized.

  It's a GenServer because that plays REALLY nicely with the existing
  Phoenix supervision tree.
  """

  # restart: :temporary means that this process will never be restarted (ie: will run once and then die)
  use GenServer, restart: :temporary
  import Ecto.Query, warn: false
  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{env: Application.get_env(:pinchflat, :env)}, opts)
  end

  @doc """
  Runs application startup tasks.

  Any code defined here will run every time the application starts. You must
  make sure that the code is idempotent and safe to run multiple times.

  This is a good place to set up default settings, create initial records, stuff like that.
  Should be fast - anything with the potential to be slow should be kicked off as a job instead.
  """
  @impl true
  def init(%{env: :test} = state) do
    # Do nothing _as part of the app bootup process_.
    # Since bootup calls `start_link` and that's where the `env` state is injected,
    # you can still call `.init()` manually to run these tasks for testing purposes
    {:ok, state}
  end

  def init(state) do
    reschedule_missing_indexing_tasks()

    {:ok, state}
  end

  # Indexing jobs are self-perpetuating: the next run is only enqueued from inside
  # a completed run. If a job exhausts its retries and is discarded (eg: during an
  # extended network or YouTube outage), the chain dies and the source would never
  # be indexed again. Re-kick any missing chains on boot.
  #
  # This runs after PreJobStartupTasks has already reset stuck `executing` jobs to
  # `retryable`, so a live chain always has a task in one of the pending states
  # checked below and won't be double-scheduled.
  defp reschedule_missing_indexing_tasks do
    sources_query = from(s in Source, where: s.enabled == true and is_nil(s.marked_for_deletion_at))

    sources_query
    |> Repo.all()
    |> Enum.each(fn source ->
      maybe_reschedule_slow_indexing(source)
      maybe_reschedule_fast_indexing(source)
    end)
  end

  defp maybe_reschedule_slow_indexing(source) do
    if source.index_frequency_minutes > 0 && !pending_task?(source, "MediaCollectionIndexingWorker") do
      Logger.info("Rescheduling missing slow indexing job for source ##{source.id}")

      SlowIndexingHelpers.kickoff_indexing_task(source)
    end
  end

  # The reschedule is delayed by the fast indexing frequency (rather than running
  # immediately) so that a boot with many sources doesn't burst RSS fetches.
  defp maybe_reschedule_fast_indexing(source) do
    if source.fast_index && !pending_task?(source, "FastIndexingWorker") do
      Logger.info("Rescheduling missing fast indexing job for source ##{source.id}")

      FastIndexingWorker.kickoff_with_task(source, schedule_in: Source.fast_index_frequency() * 60)
    end
  end

  defp pending_task?(source, worker_name) do
    Tasks.list_tasks_for(source, worker_name, [:available, :scheduled, :retryable, :executing]) != []
  end
end
