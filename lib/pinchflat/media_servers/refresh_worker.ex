defmodule Pinchflat.MediaServers.RefreshWorker do
  @moduledoc """
  Oban worker that executes library refresh requests for enabled media servers.

  Uses queue `:default` with unique debounce constraints to coalesce rapid-fire
  refreshes from multiple sequential downloads into single requests per server type.
  """

  use Oban.Worker,
    queue: :default,
    priority: 8,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :queue, :args], states: [:available, :scheduled, :retryable]]

  require Logger

  alias Pinchflat.MediaServers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"server_type" => server_type}}) do
    case MediaServers.refresh(String.to_existing_atom(server_type), nil) do
      :ok ->
        Logger.info("Media server refresh succeeded for server_type=#{server_type}")
        :ok

      {:ok, _} ->
        Logger.info("Media server refresh succeeded for server_type=#{server_type}")
        :ok

      {:error, :unconfirmed_full_scan, message} ->
        Logger.warning("Media server refresh skipped for server_type=#{server_type}: #{message}")
        :ok

      {:error, :disabled} ->
        Logger.debug("Media server refresh skipped: #{server_type} is disabled")
        :ok

      {:error, :missing_configuration} ->
        Logger.warning("Media server refresh failed for server_type=#{server_type}: missing configuration")
        :ok

      {:error, reason} ->
        Logger.error("Media server refresh failed for server_type=#{server_type}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    ArgumentError ->
      Logger.error("Media server refresh discarded: unrecognized server_type in args")
      :ok
  end
end
