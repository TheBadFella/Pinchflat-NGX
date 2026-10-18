defmodule PinchflatWeb.DownloadFailureGuidanceTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Repo

  for {message, explanation, advice} <- [
        {"ERROR: unable to write: No space left on device", "Not enough storage space", "Free space"},
        {"Download staging is unavailable: :eacces", "Storage could not be written", "writable by the app"},
        {"ERROR: HTTP Error 429: Too Many Requests", "YouTube is limiting requests", "Wait before retrying"},
        {"Sign in to confirm you\u2019re not a bot", "YouTube requested a bot check", "Cookies section"},
        {"Sign in to confirm you're not a bot", "YouTube requested a bot check", "Cookies section"},
        {"This video is available to this channel's members", "This video is unavailable to the app", "Check access"},
        {"HTTP Error 403: Forbidden", "The download failed", "cause was not recognized"},
        {"Unknown extractor failure", "The download failed", "cause was not recognized"},
        {"Post-processing script timed out", "The download failed", "cause was not recognized"}
      ] do
    test "explains #{message} without changing queue policy", %{conn: conn} do
      source = source_fixture()

      media_item_fixture(%{
        source_id: source.id,
        media_filepath: nil,
        last_error: unquote(message),
        error_type: :transient
      })

      for {module, session} <- views(source) do
        {:ok, view, _html} = live_isolated(conn, module, session: session)
        assert has_element?(view, ".download-failure", unquote(explanation))
        assert has_element?(view, ".download-failure", unquote(advice))
        assert has_element?(view, ".download-failure", "No download attempt is currently queued")
        assert has_element?(view, ".download-failure a[href='/diagnostics']", "Open diagnostics")
      end

      assert Repo.aggregate(Pinchflat.Tasks.Task, :count) == 0
    end
  end

  test "both views explain the failure, keep details collapsed and link to recovery", %{conn: conn} do
    source = source_fixture()

    item =
      media_item_fixture(%{
        source_id: source.id,
        media_filepath: nil,
        last_error: "ERROR: Sign in to confirm your age <script>bad()</script>",
        error_type: :permanent,
        prevent_download: true,
        download_prevented_reason: :error
      })

    for {module, session} <- views(source) do
      {:ok, view, _html} = live_isolated(conn, module, session: session)
      assert has_element?(view, ".download-failure", "Sign-in is required")
      assert has_element?(view, ".download-failure", "Automatic downloads are blocked for this item")
      assert has_element?(view, ".download-failure a[href='/settings']", "Open settings")
      assert has_element?(view, ".download-failure details:not([open]) summary", "Technical details")
      assert has_element?(view, ".download-failure details", item.last_error)
      refute has_element?(view, ".download-failure script")
      refute has_element?(view, ".download-failure", "automatic retry is scheduled")
      assert has_element?(view, "button[data-confirm='Force a retry of this permanent failure?']")
    end

    assert Repo.aggregate(Pinchflat.Tasks.Task, :count) == 0
  end

  test "retry guidance follows real job state without enqueueing work on render", %{conn: conn} do
    source = source_fixture()

    item =
      media_item_fixture(%{
        source_id: source.id,
        media_filepath: nil,
        last_error: "Network is unreachable",
        error_type: :transient
      })

    {:ok, task} = MediaDownloadWorker.kickoff_with_task(item)

    for {state, message} <- [
          {"retryable", "An automatic retry is scheduled"},
          {"scheduled", "A download attempt is scheduled"},
          {"available", "A download attempt is queued"},
          {"executing", "A download attempt is running"},
          {"discarded", "No download attempt is currently queued"}
        ] do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^task.job_id),
        set: [state: state, scheduled_at: ~U[2030-01-02 12:00:00Z]]
      )

      for {module, session} <- views(source) do
        {:ok, view, _html} = live_isolated(conn, module, session: session)
        assert has_element?(view, ".download-failure", "The network request failed")
        assert has_element?(view, ".download-failure", message)

        if state in ["retryable", "scheduled"] do
          assert has_element?(view, ".download-failure time", "2030-01-02")
        else
          refute has_element?(view, ".download-failure time")
        end
      end
    end

    assert Repo.aggregate(Pinchflat.Tasks.Task, :count) == 1
  end

  test "progress arriving before job state does not claim an empty queue", %{conn: conn} do
    source = source_fixture()

    item =
      media_item_fixture(%{
        source_id: source.id,
        media_filepath: nil,
        last_error: "Network is unreachable",
        error_type: :transient
      })

    for {module, session} <- views(source) do
      {:ok, view, _html} = live_isolated(conn, module, session: session)

      send(view.pid, %{
        topic: "job:progress",
        event: "update",
        payload: %{media_item_id: item.id, task_id: 123, job_id: 456, progress_percent: 1.0}
      })

      assert has_element?(view, ".download-failure", "current download queue state is unavailable")
      refute has_element?(view, ".download-failure", "No download attempt is currently queued")
    end
  end

  test "queue guidance updates on job-state events without reloading the page", %{conn: conn} do
    source = source_fixture()

    item =
      media_item_fixture(%{
        source_id: source.id,
        media_filepath: nil,
        last_error: "Network is unreachable",
        error_type: :transient
      })

    {:ok, task} = MediaDownloadWorker.kickoff_with_task(item)

    live_views =
      Enum.map(views(source), fn {module, session} ->
        {:ok, view, _html} = live_isolated(conn, module, session: session)
        view
      end)

    for {state, message} <- [
          {"retryable", "An automatic retry is scheduled"},
          {"discarded", "No download attempt is currently queued"}
        ] do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^task.job_id), set: [state: state])

      for view <- live_views do
        send(view.pid, %{
          topic: "job:state",
          event: "change",
          payload: %{media_item_id: item.id, source_id: source.id}
        })

        assert has_element?(view, ".download-failure", message)
      end
    end
  end

  defp views(source) do
    [
      {Pinchflat.Pages.HistoryTableLive, %{"media_state" => "failed"}},
      {PinchflatWeb.Sources.MediaItemTableLive, %{"source_id" => source.id, "media_state" => "failed"}}
    ]
  end
end
