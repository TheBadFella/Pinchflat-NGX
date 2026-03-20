defmodule PinchflatWeb.Pages.JobTableLiveTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.JobTableLive
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Tasks

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Nothing Here!"
      refute html =~ "Subject"
    end

    test "shows records when present", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Subject"
    end

    test "doesn't show records when not in executing state", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job(:scheduled)
      {_source, _media_item, _task, _job} = create_media_item_job(:completed)
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Nothing Here!"
      refute html =~ "Subject"
    end
  end

  describe "job rendering" do
    test "shows worker name", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Downloading Media"
    end

    test "shows the media item title", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ media_item.title
    end

    test "shows a media item link", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ ~p"/sources/#{media_item.source_id}/media/#{media_item}"
    end

    test "shows the source custom name", %{conn: conn} do
      {source, _task, _job} = create_source_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ source.custom_name
    end

    test "shows a source link", %{conn: conn} do
      {source, _task, _job} = create_source_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ ~p"/sources/#{source.id}"
    end

    test "shows subject and source ids alongside names", %{conn: conn} do
      {source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Media ##{media_item.id}"
      assert html =~ media_item.title
      assert html =~ "Source ##{source.id}"
      assert html =~ source.custom_name
    end

    test "listens for job:state change events", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, _html} = live_isolated(conn, JobTableLive, session: %{})

      PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)

      assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change", payload: nil}
    end

    test "shows download progress for media download jobs", %{conn: conn} do
      {_source, _media_item, task, _job} = create_media_item_job()

      {:ok, _task} =
        Tasks.update_task_progress(task, %{
          progress_percent: 37.5,
          progress_status: "Downloading",
          progress_downloaded_bytes: 512,
          progress_total_bytes: 1024,
          progress_eta_seconds: 30
        })

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "37.5%"
      assert html =~ "Downloading"
      assert html =~ "512.0 B of 1.0 KB done, 512.0 B remaining"
      assert html =~ "ETA 30s"
      assert html =~ "Stop"
    end

    test "shows a clearer waiting message while prechecking media", %{conn: conn} do
      {_source, _media_item, task, _job} = create_media_item_job()

      {:ok, _task} =
        Tasks.update_task_progress(task, %{
          progress_percent: 0.0,
          progress_status: "Prechecking media"
        })

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Checking the media before starting the download"
    end

    test "shows a clearer waiting message when total size is unknown", %{conn: conn} do
      {_source, _media_item, task, _job} = create_media_item_job()

      {:ok, _task} =
        Tasks.update_task_progress(task, %{
          progress_percent: 12.5,
          progress_status: "Downloading without known total",
          progress_downloaded_bytes: 2048
        })

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Downloading without known total"
      assert html =~ "2.0 KB downloaded"
    end

    test "listens for job:progress change events", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, _html} = live_isolated(conn, JobTableLive, session: %{})

      PinchflatWeb.Endpoint.broadcast("job:progress", "update", %{job_id: 123})

      assert_receive %Phoenix.Socket.Broadcast{topic: "job:progress", event: "update", payload: %{job_id: 123}}
    end

    test "can stop an active task", %{conn: conn} do
      {_source, _media_item, task, _job} = create_media_item_job()
      {:ok, view, _html} = live_isolated(conn, JobTableLive, session: %{})

      view
      |> element("button[phx-click='cancel_task'][phx-value-task-id='#{task.id}']")
      |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
    end

    test "filters tasks to a single source when source_id is provided", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {_other_source, other_media_item, _other_task, _other_job} = create_media_item_job()

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{"source_id" => media_item.source_id})

      assert html =~ media_item.title
      refute html =~ other_media_item.title
    end
  end

  defp create_media_item_job(job_state \\ :executing) do
    source = source_fixture()
    media_item = media_item_fixture(source_id: source.id)
    {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state)])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, media_item, task, job}
  end

  defp create_source_job(job_state \\ :executing) do
    source = source_fixture()
    {:ok, task} = FastIndexingWorker.kickoff_with_task(source)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state)])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, task, job}
  end
end
