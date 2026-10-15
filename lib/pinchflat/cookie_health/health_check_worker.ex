defmodule Pinchflat.CookieHealth.HealthCheckWorker do
  @moduledoc """
  Performs scheduled and on-demand cookie health checks in Oban.
  """

  use Oban.Worker,
    queue: :default,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable], fields: [:worker, :queue, :args]],
    max_attempts: 3,
    tags: ["cookie_health"]

  import Ecto.Query

  alias Pinchflat.CookieHealth
  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @doc """
  Enqueues a manual health check.

  Returns `{:ok, %Oban.Job{}} | {:error, term()}`.
  """
  def kickoff_manual(opts \\ []) when is_list(opts) do
    worker_str = to_string(__MODULE__)

    executing_job =
      Repo.one(
        from(j in Oban.Job,
          where: j.worker == ^worker_str and j.state == "executing",
          order_by: [desc: j.id],
          limit: 1
        )
      )

    if executing_job do
      {:ok, executing_job}
    else
      args = %{"manual" => true}

      manual_unique = [
        period: :infinity,
        states: [:available, :scheduled, :executing, :retryable],
        fields: [:worker, :queue, :args]
      ]

      job_opts =
        opts
        |> Keyword.take([:schedule_in, :priority, :max_attempts])
        |> Keyword.put_new(:unique, manual_unique)

      case Repo.insert_unique_job(new(args, job_opts)) do
        {:ok, job} -> {:ok, job}
        {:duplicate, job} -> {:ok, job}
        error -> error
      end
    end
  end

  @doc """
  Schedules the next periodic check if cookie health monitoring is enabled.
  """
  def schedule_next(delay_seconds \\ nil) do
    setting = Settings.record()

    if setting.cookie_health_monitoring_enabled do
      seconds = delay_seconds || max(setting.cookie_health_check_interval_hours || 6, 1) * 3600
      Repo.insert_unique_job(new(%{}, schedule_in: seconds))
    else
      :ok
    end
  end

  @doc """
  Performs a scheduled or manual cookie health check.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"manual" => true}}) do
    CookieHealth.perform_check_and_update()
    :ok
  end

  def perform(%Oban.Job{}) do
    setting = Settings.record()

    if setting.cookie_health_monitoring_enabled do
      CookieHealth.perform_check_and_update()
      schedule_next()
      :ok
    else
      {:cancel, "Cookie health monitoring is disabled"}
    end
  end
end
