defmodule PinchflatWeb.Settings.DiagnosticsController do
  use PinchflatWeb, :controller

  alias Pinchflat.Settings
  alias Pinchflat.Diagnostics.QueueDiagnostics
  alias Pinchflat.Diagnostics.DatabaseMaintenanceWorker

  def show(conn, _params) do
    render(conn, "show.html")
  end

  def reset_retryable_jobs(conn, _params) do
    count = QueueDiagnostics.reset_retryable_jobs()

    conn
    |> put_flash(:info, "Reset #{count} retryable job(s). They will be retried shortly.")
    |> redirect(to: ~p"/diagnostics")
  end

  def reset_job(conn, %{"id" => job_id}) do
    with {:ok, id} <- parse_job_id(job_id),
         1 <- QueueDiagnostics.reset_job(id) do
      conn
      |> put_flash(:info, "Job ##{job_id} has been reset and will retry shortly.")
      |> redirect(to: ~p"/diagnostics")
    else
      :error ->
        invalid_job_id(conn, job_id)

      0 ->
        conn
        |> put_flash(:error, "Job ##{job_id} could not be reset. It may have already completed or been cancelled.")
        |> redirect(to: ~p"/diagnostics")
    end
  end

  def requeue_job(conn, %{"id" => job_id}) do
    with {:ok, id} <- parse_job_id(job_id),
         {:ok, :requeued} <- QueueDiagnostics.requeue_job(id) do
      conn
      |> put_flash(:info, "Job ##{job_id} was requeued and will run again after other queued jobs.")
      |> redirect(to: ~p"/diagnostics")
    else
      :error ->
        invalid_job_id(conn, job_id)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Job ##{job_id} could not be requeued. It may have already completed.")
        |> redirect(to: ~p"/diagnostics")
    end
  end

  def delete_job(conn, %{"id" => job_id}) do
    with {:ok, id} <- parse_job_id(job_id),
         {:ok, :deleted} <- QueueDiagnostics.delete_discarded_job(id) do
      conn
      |> put_flash(:info, "Discarded job ##{job_id} has been deleted.")
      |> redirect(to: ~p"/diagnostics")
    else
      :error ->
        invalid_job_id(conn, job_id)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Job ##{job_id} could not be deleted. Only discarded jobs can be deleted.")
        |> redirect(to: ~p"/diagnostics")
    end
  end

  def vacuum_database(conn, _params) do
    case DatabaseMaintenanceWorker.kickoff() do
      {:ok, %Oban.Job{conflict?: true}} ->
        conn
        |> put_flash(:info, "A database compaction is already queued or running.")
        |> redirect(to: ~p"/diagnostics")

      {:ok, _job} ->
        conn
        |> put_flash(:info, "Database compaction queued. Its progress and outcome will show in the Database section.")
        |> redirect(to: ~p"/diagnostics")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not queue the database compaction job.")
        |> redirect(to: ~p"/diagnostics")
    end
  end

  def toggle_scheduled_compaction(conn, _params) do
    now_enabled = !Settings.get!(:database_maintenance_enabled)
    Settings.set(database_maintenance_enabled: now_enabled)

    message =
      if now_enabled do
        "Scheduled compaction turned on. It runs monthly on the 1st at 03:00."
      else
        "Scheduled compaction turned off. You can still compact manually with the Compact Now button."
      end

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/diagnostics")
  end

  # Guards against non-integer ids in the URL (which would otherwise raise).
  defp parse_job_id(job_id) do
    case Integer.parse(job_id) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp invalid_job_id(conn, job_id) do
    conn
    |> put_flash(:error, "#{job_id} is not a valid job ID.")
    |> redirect(to: ~p"/diagnostics")
  end
end
