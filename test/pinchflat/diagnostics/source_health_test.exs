defmodule Pinchflat.Diagnostics.SourceHealthTest do
  use Pinchflat.DataCase
  import Pinchflat.SourcesFixtures
  alias Pinchflat.Diagnostics.SourceHealth
  alias Pinchflat.{Repo, Sources}
  alias Pinchflat.Tasks.Task
  @now ~U[2026-10-13 12:00:00Z]
  @queues %{fast_indexing: :running, media_collection_indexing: :running}
  @worker "Pinchflat.FastIndexing.FastIndexingWorker"

  defp source(attrs \\ %{}),
    do:
      Map.merge(
        %{
          id: 1,
          custom_name: "Owned",
          enabled: true,
          fast_index: true,
          index_frequency_minutes: 43_200,
          last_indexed_at: ~U[2026-10-01 12:00:00Z]
        },
        attrs
      )

  defp success(time), do: %{state: "completed", completed_at: time, attempted_at: time}

  defp classify(source, jobs \\ [], queues \\ @queues, hold \\ false),
    do: SourceHealth.classify(source, jobs, @now, queues, hold)

  test "recent successful empty fast check does not replace or depend on full scan time" do
    row = classify(source(), [success(@now)])
    assert row.status == :healthy
    assert row.last_success_at == @now
    assert row.source.last_indexed_at == ~U[2026-10-01 12:00:00Z]
    assert row.interval_minutes == 10
    assert row.mode == "Fast check"
  end

  test "fast success becomes overdue only after interval plus documented grace" do
    assert classify(source(), [success(DateTime.add(@now, -1_200))]).status == :healthy
    assert classify(source(), [success(DateTime.add(@now, -1_201))]).status == :overdue
  end

  test "full scans use configured interval instead of a fixed 24 hours" do
    assert classify(source(%{fast_index: false})).status == :healthy
    row = source(%{fast_index: false, index_frequency_minutes: 60, last_indexed_at: DateTime.add(@now, -5_400)})
    assert classify(row).status == :healthy
    assert classify(%{row | last_indexed_at: DateTime.add(@now, -5_401)}).status == :overdue
  end

  test "no retained history and scheduled jobs are not success" do
    assert classify(source()).status == :unknown
    assert classify(source(), [%{state: "scheduled", completed_at: nil, attempted_at: nil}]).status == :pending
    assert classify(source(%{fast_index: false, last_indexed_at: nil})).status == :unknown
  end

  test "failure after success warns, but a later success clears older failures" do
    failure = %{state: "retryable", completed_at: nil, attempted_at: @now}
    assert classify(source(), [failure, success(DateTime.add(@now, -60))]).status == :failed
    assert classify(source(), [%{failure | attempted_at: DateTime.add(@now, -60)}, success(@now)]).status == :healthy
    assert classify(source(), [%{failure | state: "discarded"}]).status == :failed
  end

  test "disabled, manual, paused and held take precedence over warnings" do
    assert classify(source(%{enabled: false})).status == :disabled
    assert classify(source(%{fast_index: false, index_frequency_minutes: 0})).status == :manual
    assert classify(source(%{fast_index: false, index_frequency_minutes: nil})).status == :manual
    assert classify(source(), [], %{fast_indexing: :paused}).status == :paused
    assert classify(source(), [], @queues, true).status == :paused
    assert classify(source(), [], %{media_collection_indexing: :paused}).status == :unknown
  end

  test "active job does not claim successful indexing" do
    row = classify(source(), [%{state: "executing", completed_at: nil, attempted_at: @now}])
    assert row.status == :active
    assert row.last_success_at == nil
  end

  test "future success and cancelled history do not fabricate health or failure" do
    assert classify(source(), [success(DateTime.add(@now, 60))]).status == :unknown
    cancelled = %{state: "cancelled", completed_at: nil, attempted_at: @now}
    assert classify(source(), [cancelled]).status == :unknown
    assert classify(source(), [cancelled, success(@now)]).status == :healthy
  end

  test "snapshot batches backend-safe success evidence and shares counts with attention" do
    fast = source_fixture(%{fast_index: true, last_indexed_at: DateTime.add(@now, -10, :day)})

    full =
      source_fixture(%{
        fast_index: false,
        index_frequency_minutes: 43_200,
        last_indexed_at: DateTime.add(@now, -3, :day)
      })

    unknown = source_fixture(%{fast_index: true})
    complete(fast, @worker, @now)
    complete(unknown, "Pinchflat.Metadata.SourceMetadataStorageWorker", @now)
    result = SourceHealth.snapshot(now: @now, queues: @queues, migration_hold: false)
    assert result.stats.total == 3
    assert result.stats.healthy == 2
    assert result.stats.unknown == 1
    assert Enum.map(result.attention, & &1.source.id) == [unknown.id]
    assert Repo.get!(Pinchflat.Sources.Source, full.id).last_indexed_at == full.last_indexed_at
    job = Repo.one!(from j in Oban.Job, where: j.worker == ^@worker)
    Repo.delete!(job)
    result = SourceHealth.snapshot(now: @now, queues: @queues, migration_hold: false)
    assert result.stats.unknown == 2
  end

  test "attention is bounded while counts include every classified source" do
    profile = Pinchflat.ProfilesFixtures.media_profile_fixture()
    for _ <- 1..12, do: source_fixture(%{media_profile_id: profile.id, fast_index: true})
    result = SourceHealth.snapshot(now: @now, queues: @queues, migration_hold: false)
    assert result.stats.unknown == 12
    assert length(result.attention) == 10
  end

  test "one or many sources use two queries and do not mutate records or jobs" do
    profile = Pinchflat.ProfilesFixtures.media_profile_fixture()
    source_fixture(%{media_profile_id: profile.id, fast_index: true})
    assert query_count() == 2
    for _ <- 1..25, do: source_fixture(%{media_profile_id: profile.id, fast_index: true})
    before = {Repo.all(Pinchflat.Sources.Source), Repo.all(Oban.Job), Repo.all(Task)}
    assert query_count() == 2
    assert before == {Repo.all(Pinchflat.Sources.Source), Repo.all(Oban.Job), Repo.all(Task)}
  end

  test "ordinary partial updates retain frequency rules and single-video restrictions" do
    saved = source_fixture(%{fast_index: true, index_frequency_minutes: 43_200})
    assert Ecto.Changeset.get_field(Sources.change_source(saved, %{custom_name: "Renamed"}), :fast_index)

    {:ok, unchanged} = Sources.update_source(saved, %{custom_name: "Renamed"}, run_post_commit_tasks: false)
    assert unchanged.fast_index
    assert unchanged.index_frequency_minutes == 43_200

    {:ok, normalized} =
      Sources.update_source(unchanged, %{fast_index: true, index_frequency_minutes: 60}, run_post_commit_tasks: false)

    assert normalized.index_frequency_minutes == 43_200

    {:ok, normal} =
      Sources.update_source(normalized, %{fast_index: false, index_frequency_minutes: 180},
        run_post_commit_tasks: false
      )

    assert normal.index_frequency_minutes == 180
    refute normal.fast_index
    single = source_fixture(%{collection_type: :video})

    {:ok, single} =
      Sources.update_source(single, %{fast_index: true, index_frequency_minutes: 60}, run_post_commit_tasks: false)

    refute single.fast_index
    assert single.index_frequency_minutes == 0
  end

  defp complete(source, worker, at) do
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    job =
      Repo.insert!(%Oban.Job{
        worker: worker,
        queue: "fast_indexing",
        state: "completed",
        args: %{"id" => source.id},
        completed_at: at
      })

    Repo.insert!(%Task{source_id: source.id, job_id: job.id})
  end

  defp query_count do
    ref = make_ref()
    caller = self()
    :telemetry.attach(ref, [:pinchflat, :repo, :query], fn _, _, _, _ -> send(caller, ref) end, nil)

    try do
      SourceHealth.snapshot(now: @now, queues: @queues, migration_hold: false)
      collect(ref, 0)
    after
      :telemetry.detach(ref)
    end
  end

  defp collect(ref, count) do
    receive do
      ^ref -> collect(ref, count + 1)
    after
      0 -> count
    end
  end
end
