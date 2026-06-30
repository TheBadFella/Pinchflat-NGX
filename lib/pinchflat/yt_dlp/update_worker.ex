defmodule Pinchflat.YtDlp.UpdateWorker do
  @moduledoc """
  Keeps the yt-dlp executable up to date according to the configured update
  policy (see `Pinchflat.YtDlp.UpdateManager`).

  Runs on a schedule (Oban Cron) and on app boot for the recurring policy
  behaviour. Can also be enqueued with `%{"apply_policy" => true}` to perform the
  one-shot jump immediately after the user changes the policy in settings.
  """

  use Oban.Worker,
    queue: :local_data,
    tags: ["local_data"]

  alias __MODULE__
  alias Pinchflat.YtDlp.UpdateManager

  @doc """
  Starts the yt-dlp update worker for a normal scheduled run.

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff do
    Oban.insert(UpdateWorker.new(%{}))
  end

  @doc """
  Starts the yt-dlp update worker to immediately apply the current policy
  (the one-shot jump performed after a settings change).

  Returns {:ok, %Oban.Job{}} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_apply do
    Oban.insert(UpdateWorker.new(%{apply_policy: true}))
  end

  @doc """
  Updates yt-dlp based on the configured policy and saves the resulting version
  to settings.

  This worker is scheduled to run via the Oban Cron plugin as well as on app boot.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Map.get(args, "apply_policy", false) do
      UpdateManager.apply_policy()
    else
      UpdateManager.run_scheduled_update()
    end

    :ok
  end
end
