defmodule Pinchflat.MediaWatch.DispatcherWorker do
  @moduledoc """
  Enqueues bounded observation work for due watches.

  Runs every 15 minutes from Oban's cron and never performs a remote request
  itself. Expired, disabled and orphaned watches are filtered in the query.
  """

  use Oban.Worker,
    queue: :media_watch,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]],
    tags: ["media_watch"]

  require Logger

  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.ObservationWorker

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Pinchflat.LegacyMigration.legacy_migration_pending?() do
      Logger.info("Legacy migration review is pending; skipping watch observation dispatch")
      :ok
    else
      Enum.each(MediaWatch.recover_pending(), fn
        %{watch_id: id, action: {:error, reason}} ->
          Logger.warning("Watch recovery remains pending for watch ##{id}: #{inspect(reason)}")

        _ ->
          :ok
      end)

      watch_ids = MediaWatch.list_due_watch_ids(DateTime.utc_now() |> DateTime.truncate(:second), @batch_size)

      Enum.each(watch_ids, fn watch_id ->
        %{"id" => watch_id}
        |> ObservationWorker.new()
        |> Oban.insert()
      end)

      :ok
    end
  end
end
