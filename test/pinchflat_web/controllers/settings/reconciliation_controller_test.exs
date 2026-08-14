defmodule PinchflatWeb.Settings.ReconciliationControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Reconciliation
  alias Pinchflat.Reconciliation.ReconcilePlan
  alias Pinchflat.Reconciliation.ReconcileWorker

  describe "show" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/reconciliation")

      assert html_response(conn, 200) =~ "Scan and Build Plan"
    end

    test "renders with an existing plan and a preselected source", %{conn: conn} do
      source = source_fixture()
      {:ok, _plan} = Reconciliation.create_plan(%{mode: :local, source_id: source.id, status: :ready})

      conn = get(conn, ~p"/reconciliation?source_id=#{source.id}")

      assert html_response(conn, 200) =~ "Past Runs"
    end
  end

  describe "build" do
    test "starts a dry run and redirects", %{conn: conn} do
      conn = post(conn, ~p"/reconciliation", plan: %{mode: "local", source_id: "all"})

      assert redirected_to(conn) == ~p"/reconciliation"
      assert conn.assigns[:flash]["info"] =~ "Scan started"
      assert [%ReconcilePlan{source_id: nil, mode: :local}] = Repo.all(ReconcilePlan)
    end

    test "scopes the run to a source when given", %{conn: conn} do
      source = source_fixture()

      post(conn, ~p"/reconciliation", plan: %{mode: "full", source_id: to_string(source.id)})

      assert [%ReconcilePlan{mode: :full, source_id: source_id}] = Repo.all(ReconcilePlan)
      assert source_id == source.id
    end

    test "shows an error when a run is already queued", %{conn: conn} do
      {:ok, _} = ReconcileWorker.kickoff_build(:local)

      conn = post(conn, ~p"/reconciliation", plan: %{mode: "local", source_id: "all"})

      assert conn.assigns[:flash]["error"] =~ "already queued or running"
    end
  end

  describe "apply" do
    test "kicks off the apply job for a ready plan", %{conn: conn} do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :ready})

      conn = post(conn, ~p"/reconciliation/apply/#{plan.id}")

      assert redirected_to(conn) == ~p"/reconciliation"
      assert conn.assigns[:flash]["info"] =~ "Applying the plan"
    end

    test "shows an error for a stale plan", %{conn: conn} do
      {:ok, plan} = Reconciliation.create_plan(%{mode: :local, status: :stale})

      conn = post(conn, ~p"/reconciliation/apply/#{plan.id}")

      assert conn.assigns[:flash]["error"] =~ "no longer be applied"
    end
  end
end
