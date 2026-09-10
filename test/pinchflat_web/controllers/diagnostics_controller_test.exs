defmodule PinchflatWeb.DiagnosticsControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Repo
  import Ecto.Query
  import Pinchflat.MediaFixtures
  import Pinchflat.Downloading.MediaDownloadWorker

  setup do
    media_item = media_item_fixture(%{media_filepath: nil})
    {:ok, task} = kickoff_with_task(media_item)

    {:ok, %{media_item: media_item, task: task}}
  end

  describe "show diagnostics" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/diagnostics")

      assert html_response(conn, 200) =~ "Diagnostics"
      assert html_response(conn, 200) =~ "Queue Health"
      assert html_response(conn, 200) =~ "PO-token Provider"
      assert html_response(conn, 200) =~ "Disabled"
      assert html_response(conn, 200) =~ "flex-col gap-3 sm:flex-row"
      assert html_response(conn, 200) =~ "flex w-full flex-col gap-3 sm:w-auto sm:flex-row"
    end

    test "shows a healthy configured provider without exposing response data", %{conn: conn} do
      original_url = Application.get_env(:pinchflat, :po_token_provider_url)
      Application.put_env(:pinchflat, :po_token_provider_url, "http://pot-provider:4416")

      on_exit(fn -> Application.put_env(:pinchflat, :po_token_provider_url, original_url) end)

      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"server_uptime":12.5,"version":"2.0.0","poToken":"must-not-render"})}
      end)

      conn = get(conn, ~p"/diagnostics")
      html = html_response(conn, 200)

      assert html =~ "Healthy"
      refute html =~ "must-not-render"
    end
  end

  describe "test_po_token_provider" do
    test "returns a bounded flash result", %{conn: conn} do
      original_url = Application.get_env(:pinchflat, :po_token_provider_url)
      Application.put_env(:pinchflat, :po_token_provider_url, "http://pot-provider:4416")

      on_exit(fn -> Application.put_env(:pinchflat, :po_token_provider_url, original_url) end)

      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"server_uptime":1,"version":"2.0.0"})}
      end)

      conn = post(conn, ~p"/diagnostics/test_po_token_provider")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] == "PO-token provider is healthy."
    end
  end

  describe "reset_retryable_jobs" do
    test "resets retryable jobs", %{conn: conn, task: task} do
      Oban.Job
      |> Repo.get!(task.job_id)
      |> Ecto.Changeset.change(%{state: "retryable"})
      |> Repo.update!()

      conn = post(conn, ~p"/diagnostics/reset_retryable_jobs")
      assert redirected_to(conn) == ~p"/diagnostics"

      job = Repo.get!(Oban.Job, task.job_id)
      assert job.state == "available"
    end
  end

  describe "reset_job" do
    test "resets a single job", %{conn: conn, task: task} do
      Oban.Job
      |> Repo.get!(task.job_id)
      |> Ecto.Changeset.change(%{state: "discarded"})
      |> Repo.update!()

      conn = post(conn, ~p"/diagnostics/reset_job/#{task.job_id}")
      assert redirected_to(conn) == ~p"/diagnostics"

      job = Repo.get!(Oban.Job, task.job_id)
      assert job.state == "available"
    end

    test "handles invalid job ID", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/reset_job/invalid")
      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] == "invalid is not a valid job ID."
    end
  end

  describe "requeue_job" do
    test "requeues a job", %{conn: conn, task: task} do
      Oban.Job
      |> Repo.get!(task.job_id)
      |> Ecto.Changeset.change(%{state: "retryable"})
      |> Repo.update!()

      conn = post(conn, ~p"/diagnostics/requeue_job/#{task.job_id}")
      assert redirected_to(conn) == ~p"/diagnostics"

      old_job = Repo.get!(Oban.Job, task.job_id)
      assert old_job.state == "cancelled"

      new_job = Repo.one!(from j in Oban.Job, where: j.id != ^task.job_id)
      assert new_job.state == "available"
    end

    test "handles invalid job ID", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/requeue_job/invalid")
      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] == "invalid is not a valid job ID."
    end
  end

  describe "delete_job" do
    test "deletes a discarded job and task", %{conn: conn, task: task} do
      Oban.Job
      |> Repo.get!(task.job_id)
      |> Ecto.Changeset.change(%{state: "discarded"})
      |> Repo.update!()

      conn = post(conn, ~p"/diagnostics/delete_job/#{task.job_id}")
      assert redirected_to(conn) == ~p"/diagnostics"

      assert Repo.get(Oban.Job, task.job_id) == nil
    end

    test "handles invalid job ID", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/delete_job/invalid")
      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] == "invalid is not a valid job ID."
    end
  end

  describe "vacuum_database" do
    test "enqueues a maintenance job and redirects", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/vacuum_database")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "Database compaction queued"
      assert [_] = all_enqueued(worker: Pinchflat.Diagnostics.DatabaseMaintenanceWorker)
    end

    test "reports when a maintenance job is already queued", %{conn: conn} do
      post(conn, ~p"/diagnostics/vacuum_database")
      conn = post(conn, ~p"/diagnostics/vacuum_database")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "already queued or running"
      assert [_] = all_enqueued(worker: Pinchflat.Diagnostics.DatabaseMaintenanceWorker)
    end
  end

  describe "toggle_scheduled_compaction" do
    test "turns scheduled compaction on", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/toggle_scheduled_compaction")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "Scheduled compaction turned on"
      assert Pinchflat.Settings.get!(:database_maintenance_enabled) == true
    end

    test "turns scheduled compaction off when it is on", %{conn: conn} do
      Pinchflat.Settings.set(database_maintenance_enabled: true)

      conn = post(conn, ~p"/diagnostics/toggle_scheduled_compaction")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "Scheduled compaction turned off"
      assert Pinchflat.Settings.get!(:database_maintenance_enabled) == false
    end
  end
end
