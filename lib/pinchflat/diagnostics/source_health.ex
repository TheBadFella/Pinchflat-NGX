defmodule Pinchflat.Diagnostics.SourceHealth do
  @moduledoc """
  Read-only indexing health. Full scans and fast checks have distinct evidence.
  Pruned/missing fast-check history is unknown, never proof of success or failure.
  """
  import Ecto.Query
  alias Pinchflat.{LegacyMigration, Repo}
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task

  @fast_worker "Pinchflat.FastIndexing.FastIndexingWorker"
  @full_worker "Pinchflat.SlowIndexing.MediaCollectionIndexingWorker"

  def snapshot(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    hold = Keyword.get_lazy(opts, :migration_hold, &LegacyMigration.legacy_migration_pending?/0)
    queues = Keyword.get_lazy(opts, :queues, &queue_states/0)

    sources =
      Repo.all(
        from s in Source,
          select: map(s, [:id, :custom_name, :enabled, :fast_index, :index_frequency_minutes, :last_indexed_at])
      )

    evidence =
      Repo.all(
        from t in Task,
          join: j in assoc(t, :job),
          where: j.worker in [@fast_worker, @full_worker],
          where: j.state in ["completed", "executing", "available", "scheduled", "retryable", "discarded"],
          group_by: [t.source_id, j.worker, j.state],
          select: %{
            source_id: t.source_id,
            worker: j.worker,
            state: j.state,
            completed_at: max(j.completed_at),
            attempted_at: max(j.attempted_at)
          }
      )
      |> Enum.group_by(&{&1.source_id, &1.worker})

    rows =
      Enum.map(sources, fn source ->
        worker = if source.fast_index, do: @fast_worker, else: @full_worker
        classify(source, Map.get(evidence, {source.id, worker}, []), now, queues, hold)
      end)

    counts = Enum.frequencies_by(rows, & &1.status)

    stats =
      Map.new(
        [:healthy, :overdue, :failed, :unknown, :paused, :manual, :active, :pending, :disabled],
        &{&1, Map.get(counts, &1, 0)}
      )

    stats = Map.merge(stats, %{total: length(rows), enabled: Enum.count(sources, & &1.enabled)})

    attention =
      rows
      |> Enum.filter(&(&1.status in [:overdue, :failed, :unknown]))
      |> Enum.sort_by(&{&1.status, &1.source.id})
      |> Enum.take(10)

    %{stats: stats, attention: attention}
  end

  def classify(source, evidence, now, queues, hold) do
    queue = if source.fast_index, do: :fast_indexing, else: :media_collection_indexing
    minutes = if source.fast_index, do: Source.fast_index_frequency(), else: source.index_frequency_minutes
    completed = evidence |> Enum.filter(&(&1.state == "completed")) |> Enum.map(& &1.completed_at) |> latest()
    success = if source.fast_index, do: completed, else: latest([source.last_indexed_at, completed])

    failure =
      evidence |> Enum.filter(&(&1.state in ["retryable", "discarded"])) |> Enum.map(& &1.attempted_at) |> latest()

    active = Enum.any?(evidence, &(&1.state == "executing"))
    pending = Enum.any?(evidence, &(&1.state in ["available", "scheduled", "retryable"]))
    # Allow half an interval (minimum ten minutes) for scheduling/provider delays.
    grace = max(div(minutes || 0, 2), 10)

    status =
      cond do
        not source.enabled -> :disabled
        not source.fast_index and (is_nil(minutes) or minutes <= 0) -> :manual
        hold or Map.get(queues, queue) == :paused -> :paused
        Map.get(queues, queue) != :running -> :unknown
        active -> :active
        failure && (is_nil(success) or DateTime.compare(failure, success) == :gt) -> :failed
        is_nil(success) and pending -> :pending
        is_nil(success) -> :unknown
        DateTime.compare(success, now) == :gt -> :unknown
        DateTime.diff(now, success, :second) > (minutes + grace) * 60 -> :overdue
        true -> :healthy
      end

    %{
      source: source,
      status: status,
      last_success_at: success,
      mode: if(source.fast_index, do: "Fast check", else: "Full scan"),
      interval_minutes: minutes,
      grace_minutes: grace
    }
  end

  defp latest(values),
    do: values |> Enum.reject(&is_nil/1) |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)

  defp queue_states do
    Map.new([:fast_indexing, :media_collection_indexing], fn queue ->
      state =
        case Oban.check_queue(queue: queue) do
          %{paused: true} -> :paused
          %{paused: false} -> :running
          _ -> :unknown
        end

      {queue, state}
    end)
  end
end
