defmodule PinchflatWeb.Settings.ReconciliationController do
  use PinchflatWeb, :controller

  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.ReconcileWorker

  def show(conn, params) do
    render(conn, "show.html",
      sources: list_sources(),
      plans: Repo.preload(Reconciliation.list_plans(), :source),
      preselected_source_id: params["source_id"]
    )
  end

  def build(conn, %{"plan" => %{"mode" => mode} = plan_params}) when mode in ~w(local online full) do
    source = find_scope_source(plan_params["source_id"])

    case ReconcileWorker.kickoff_build(String.to_existing_atom(mode), source) do
      {:ok, _} ->
        conn
        |> put_flash(
          :info,
          "Scan started. The report below updates as it builds. This can take a long time depending on the number of files and the speed of your storage."
        )
        |> redirect(to: ~p"/reconciliation")

      {:error, :duplicate_job} ->
        conn
        |> put_flash(:error, "A reconcile run is already queued or running. Wait for it to finish first.")
        |> redirect(to: ~p"/reconciliation")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not start the dry run.")
        |> redirect(to: ~p"/reconciliation")
    end
  end

  def apply(conn, %{"plan_id" => plan_id}) do
    plan = Reconciliation.get_plan!(plan_id)

    case ReconcileWorker.kickoff_apply(plan) do
      {:ok, _} ->
        conn
        |> put_flash(
          :info,
          "Applying the plan. Job queues are paused while running jobs finish, then files are " <>
            "moved and the queues resume on their own."
        )
        |> redirect(to: ~p"/reconciliation")

      {:error, :not_ready} ->
        conn
        |> put_flash(:error, "This plan can no longer be applied — run a fresh dry run.")
        |> redirect(to: ~p"/reconciliation")

      {:error, :duplicate_job} ->
        conn
        |> put_flash(:error, "A reconcile run is already queued or running.")
        |> redirect(to: ~p"/reconciliation")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not start applying the plan.")
        |> redirect(to: ~p"/reconciliation")
    end
  end

  defp list_sources do
    Sources.list_sources()
    |> Enum.reject(& &1.marked_for_deletion_at)
    |> Enum.sort_by(&String.downcase(&1.custom_name || ""))
  end

  defp find_scope_source(source_id) when source_id in [nil, "", "all"], do: nil

  defp find_scope_source(source_id) do
    case Integer.parse(source_id) do
      {id, ""} -> Repo.get(Source, id)
      _ -> nil
    end
  end
end
