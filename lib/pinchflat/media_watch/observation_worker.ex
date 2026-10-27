defmodule Pinchflat.MediaWatch.ObservationWorker do
  @moduledoc """
  Observes one watched media item and records the normalized result.

  The worker rechecks the migration hold, expiry and effective policy before
  making an external request. Duplicate dispatches are deduplicated by Oban.
  """

  use Oban.Worker,
    queue: :media_watch,
    priority: 5,
    max_attempts: 3,
    unique: [period: 900, fields: [:args], states: [:available, :scheduled, :executing, :retryable]],
    tags: ["media_watch"]

  require Logger

  alias Pinchflat.MediaWatch
  alias Pinchflat.MediaWatch.Observer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case MediaWatch.get_watch(id) do
      nil ->
        :ok

      watch ->
        case MediaWatch.observation_eligible?(watch) do
          :ok ->
            watch
            |> Observer.observe()
            |> then(&MediaWatch.record_observation(watch, &1))
            |> case do
              {:ok, _result} ->
                :ok

              {:error, reason} ->
                Logger.warning("Watch observation for ##{id} was not recorded: #{inspect(reason)}")
                :ok
            end

          {:skip, reason} ->
            Logger.debug("Watch observation for ##{id} skipped: #{inspect(reason)}")
            :ok
        end
    end
  end
end
