defmodule Pinchflat.Discovery.Worker do
  @moduledoc """
  Runs a bounded channel discovery scan in Oban.

  The worker is scheduled daily, but scheduled jobs cancel cheaply while the
  global setting is disabled. Manual kickoff is explicit user intent and is
  allowed to run while the scheduled gate is off.
  """

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :queue]],
    max_attempts: 3,
    tags: ["channel_discovery", "local_data"]

  alias Pinchflat.Discovery
  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @doc """
  Enqueues a manual discovery scan.

  Returns `{:ok, %Oban.Job{}} | {:error, :duplicate_job} | {:error, term()}`.
  """
  def kickoff(opts \\ []) when is_list(opts) do
    args = %{"manual" => true}
    job_opts = Keyword.take(opts, [:schedule_in, :priority, :max_attempts])

    case Repo.insert_unique_job(new(args, job_opts)) do
      {:ok, job} -> {:ok, job}
      {:duplicate, _job} -> {:error, :duplicate_job}
      error -> error
    end
  end

  @doc """
  Performs a scheduled or manual scan.

  Scheduled work is disabled by default through `channel_discovery_enabled`.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"manual" => true}}) do
    run_scan(manual: true)
  end

  def perform(%Oban.Job{}) do
    if Settings.get!(:channel_discovery_enabled) do
      run_scan(manual: false)
    else
      Discovery.broadcast_completion(%{status: :disabled, candidate_count: 0, validated_count: 0, inserted_count: 0})
      {:cancel, "Scheduled channel discovery is disabled"}
    end
  end

  defp run_scan(opts) do
    case Discovery.scan(Keyword.put(opts, :broadcast, true)) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :discovery_scan_failed}
    end
  end
end
