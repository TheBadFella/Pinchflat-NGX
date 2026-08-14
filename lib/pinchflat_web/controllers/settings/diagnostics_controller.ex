defmodule PinchflatWeb.Settings.DiagnosticsController do
  use PinchflatWeb, :controller

  alias Pinchflat.Diagnostics.QueueDiagnostics

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
