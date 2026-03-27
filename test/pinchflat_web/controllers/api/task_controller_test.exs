defmodule PinchflatWeb.Api.TaskControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.TasksFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Tasks

  describe "GET /api/tasks" do
    test "returns list of tasks", %{conn: conn} do
      task1 = task_fixture()
      task2 = task_fixture()

      conn = get(conn, "/api/tasks")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert task1.id in ids
      assert task2.id in ids
    end

    test "returns all expected fields in response", %{conn: conn} do
      task_fixture()

      conn = get(conn, "/api/tasks")
      response = json_response(conn, 200)

      [task_data | _] = response["data"]

      assert Map.has_key?(task_data, "id")
      assert Map.has_key?(task_data, "job_id")
      assert Map.has_key?(task_data, "source_id")
      assert Map.has_key?(task_data, "media_item_id")
      assert Map.has_key?(task_data, "worker")
      assert Map.has_key?(task_data, "state")
      assert Map.has_key?(task_data, "args")
      assert Map.has_key?(task_data, "errors")
      assert Map.has_key?(task_data, "progress_percent")
      assert Map.has_key?(task_data, "progress_status")
      assert Map.has_key?(task_data, "progress_downloaded_bytes")
      assert Map.has_key?(task_data, "progress_total_bytes")
      assert Map.has_key?(task_data, "progress_eta_seconds")
      assert Map.has_key?(task_data, "progress_speed_bytes_per_second")
      assert Map.has_key?(task_data, "attempt")
      assert Map.has_key?(task_data, "max_attempts")
      assert Map.has_key?(task_data, "inserted_at")
      assert Map.has_key?(task_data, "scheduled_at")
      assert Map.has_key?(task_data, "attempted_at")
      assert Map.has_key?(task_data, "completed_at")
    end

    test "filters by source_id", %{conn: conn} do
      source = source_fixture()
      task = task_fixture(%{source_id: source.id})
      _other_task = task_fixture()

      conn = get(conn, "/api/tasks?source_id=#{source.id}")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert ids == [task.id]
    end

    test "filters by media_item_id", %{conn: conn} do
      media_item = media_item_fixture()
      task = task_fixture(%{media_item_id: media_item.id, source_id: nil})
      _other_task = task_fixture()

      conn = get(conn, "/api/tasks?media_item_id=#{media_item.id}")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert ids == [task.id]
    end

    test "filters by worker name", %{conn: conn} do
      task = task_fixture()
      _other_task = task_fixture()

      # Get the worker name from the fixture's job
      job = Repo.get!(Oban.Job, task.job_id)
      worker_name = job.worker |> String.split(".") |> List.last()

      conn = get(conn, "/api/tasks?worker=#{worker_name}")
      response = json_response(conn, 200)

      # All tasks use TestJobWorker, so both should be returned
      refute response["data"] == []
    end

    test "filters by state", %{conn: conn} do
      task = task_fixture()

      conn = get(conn, "/api/tasks?state=available")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert task.id in ids
    end

    test "returns empty list for non-matching state filter", %{conn: conn} do
      _task = task_fixture()

      conn = get(conn, "/api/tasks?state=completed")
      response = json_response(conn, 200)

      assert response["data"] == []
    end

    test "returns 404 for non-existent source_id", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/tasks?source_id=999999")
      end
    end

    test "returns 404 for non-existent media_item_id", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/tasks?media_item_id=999999")
      end
    end

    test "returns empty list when no tasks exist", %{conn: conn} do
      conn = get(conn, "/api/tasks")
      response = json_response(conn, 200)

      assert response["data"] == []
    end
  end

  describe "GET /api/tasks/:id" do
    test "returns task details", %{conn: conn} do
      task = task_fixture()

      conn = get(conn, "/api/tasks/#{task.id}")
      response = json_response(conn, 200)

      assert response["id"] == task.id
      assert response["job_id"] == task.job_id
      assert Map.has_key?(response, "worker")
      assert Map.has_key?(response, "state")
    end

    test "returns 404 when task does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/tasks/99999")
      end
    end
  end

  describe "DELETE /api/tasks/:id" do
    test "cancels and deletes task", %{conn: conn} do
      task = task_fixture()

      conn = delete(conn, "/api/tasks/#{task.id}")
      response = json_response(conn, 200)

      assert response["message"] == "Task cancelled successfully"
      refute Tasks.list_tasks() |> Enum.any?(&(&1.id == task.id))
    end

    test "returns 404 when task does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        delete(conn, "/api/tasks/99999")
      end
    end
  end
end
