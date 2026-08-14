defmodule PinchflatWeb.DiagnosticsControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Repo
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
end
