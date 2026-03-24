defmodule Pinchflat.YtDlp.UpdateWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    tags: ["local_data"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Settings

  @doc """
  Starts the yt-dlp update worker. Does not attach it to a task like `kickoff_with_task/2`

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff do
    Oban.insert(UpdateWorker.new(%{}))
  end

  @doc """
  Updates yt-dlp and saves the version to the settings.

  This worker is scheduled to run via the Oban Cron plugin as well as on app boot.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Updating yt-dlp")

    case yt_dlp_runner().update() do
      {:ok, _output} ->
        :ok

      {:error, output} ->
        Logger.warning("yt-dlp update failed: #{inspect(output)}")
    end

    case yt_dlp_runner().version() do
      {:ok, yt_dlp_version} ->
        Settings.set(yt_dlp_version: yt_dlp_version)

      {:error, output} ->
        Logger.warning("yt-dlp version check failed after update attempt: #{inspect(output)}")
    end

    :ok
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
