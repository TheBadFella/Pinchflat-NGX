defmodule PinchflatWeb.Pages.HistoryTableLiveTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.HistoryTableLive
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Repo

  describe "pending ordering" do
    test "shows executing downloads before later queued pending items across pages", %{conn: conn} do
      source = source_fixture()

      older_executing_item =
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          uploaded_at: ~U[2024-01-01 00:00:00Z]
        )

      for day <- 2..12 do
        media_item_fixture(
          source_id: source.id,
          media_filepath: nil,
          uploaded_at: DateTime.add(~U[2024-01-01 00:00:00Z], day * 86_400, :second)
        )
      end

      {:ok, task} = MediaDownloadWorker.kickoff_with_task(older_executing_item)

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "executing"])

      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "pending"})

      assert html =~ older_executing_item.title
    end
  end

  describe "failed tab" do
    test "lists pending items that have a last_error", %{conn: conn} do
      source = source_fixture()
      failed = media_item_fixture(%{source_id: source.id, media_filepath: nil, last_error: "Network is unreachable"})
      _healthy = media_item_fixture(%{source_id: source.id, media_filepath: nil, last_error: nil})

      {:ok, view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "failed"})

      assert html =~ failed.title
      refute html =~ "Nothing Here!"
      assert html =~ "Retry All Failed"

      view
      |> element("button", "Retry All Failed")
      |> render_click()

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => failed.id})
    end

    test "filters failures by type and labels retry actions", %{conn: conn} do
      source = source_fixture()

      transient =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: nil,
          last_error: "Network is unreachable",
          error_type: :transient,
          title: "ALPHA_TRANSIENT_ITEM"
        })

      permanent =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: :error,
          last_error: "Video unavailable",
          error_type: :permanent,
          title: "OMEGA_PERMANENT_ITEM"
        })

      {:ok, view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "failed"})

      assert html =~ transient.title
      assert html =~ permanent.title
      assert html =~ "Retry Now"
      assert html =~ "Force Retry"

      render_change(view, "filter_error_type", %{"error_type" => "permanent"})
      html = render(view)

      assert html =~ permanent.title
      refute html =~ transient.title
      assert html =~ "Permanent failure"
    end
  end

  describe "sorting" do
    test "sorts by upload date and toggles the direction", %{conn: conn} do
      source = source_fixture()
      older = media_item_fixture(%{source_id: source.id, title: "Older", uploaded_at: ~U[2024-01-01 00:00:00Z]})
      newer = media_item_fixture(%{source_id: source.id, title: "Newer", uploaded_at: ~U[2024-01-02 00:00:00Z]})

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      view |> element("th button", "Upload Date") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ older.title
      assert render_element(view, "tbody tr:last-child") =~ newer.title
      assert render(view) =~ ~s(aria-sort="ascending")

      view |> element("th button", "Upload Date") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ newer.title
      assert render_element(view, "tbody tr:last-child") =~ older.title
      assert render(view) =~ ~s(aria-sort="descending")
    end

    test "sorts pending history by upload date", %{conn: conn} do
      source = source_fixture()

      older =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: nil,
          title: "Older",
          uploaded_at: ~U[2024-01-01 00:00:00Z]
        })

      newer =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: nil,
          title: "Newer",
          uploaded_at: ~U[2024-01-02 00:00:00Z]
        })

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "pending"})

      view |> element("th button", "Upload Date") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ older.title
      assert render_element(view, "tbody tr:last-child") =~ newer.title
    end

    test "sorts failed history by upload date", %{conn: conn} do
      source = source_fixture()

      older =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: nil,
          last_error: "Older failure",
          title: "Older",
          uploaded_at: ~U[2024-01-01 00:00:00Z]
        })

      newer =
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: nil,
          last_error: "Newer failure",
          title: "Newer",
          uploaded_at: ~U[2024-01-02 00:00:00Z]
        })

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "failed"})

      view |> element("th button", "Upload Date") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ older.title
      assert render_element(view, "tbody tr:last-child") =~ newer.title
    end

    test "uses ascending IDs to break equal timestamp ties", %{conn: conn} do
      source = source_fixture()
      first = media_item_fixture(%{source_id: source.id, title: "First", uploaded_at: ~U[2024-01-01 00:00:00Z]})
      second = media_item_fixture(%{source_id: source.id, title: "Second", uploaded_at: first.uploaded_at})

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      view |> element("th button", "Upload Date") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ first.title
      assert render_element(view, "tbody tr:last-child") =~ second.title
    end

    test "sorts indexed and downloaded dates with deterministic null handling", %{conn: conn} do
      source = source_fixture()
      older = media_item_fixture(%{source_id: source.id, title: "Older", media_downloaded_at: nil})
      newer = media_item_fixture(%{source_id: source.id, title: "Newer", media_downloaded_at: ~U[2024-01-02 00:00:00Z]})

      Repo.update_all(
        from(media_item in MediaItem, where: media_item.id == ^older.id),
        set: [inserted_at: ~U[2024-01-01 00:00:00Z]]
      )

      Repo.update_all(
        from(media_item in MediaItem, where: media_item.id == ^newer.id),
        set: [inserted_at: ~U[2024-01-02 00:00:00Z]]
      )

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      view |> element("th button", "Indexed At") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ older.title
      assert render_element(view, "tbody tr:last-child") =~ newer.title

      view |> element("th button", "Downloaded At") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ newer.title
      assert render_element(view, "tbody tr:last-child") =~ older.title
    end

    test "resets to the first page and ignores unknown sort keys", %{conn: conn} do
      source = source_fixture()

      for index <- 1..11 do
        media_item_fixture(%{source_id: source.id, title: "Item #{index}", uploaded_at: ~U[2024-01-01 00:00:00Z]})
      end

      {:ok, view, _html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      view |> element("span.pagination-next") |> render_click()
      assert pagination_text(view) == "Page 2 of 2"

      socket = %{assigns: %{sort_key: nil, sort_direction: :desc}}
      assert {:noreply, ^socket} = HistoryTableLive.handle_event("sort_update", %{"sort_key" => "not_a_field"}, socket)

      view |> element("th button", "Upload Date") |> render_click()
      assert pagination_text(view) == "Page 1 of 2"
    end
  end

  defp render_element(view, selector) do
    view
    |> element(selector)
    |> render()
  end

  defp pagination_text(view) do
    view
    |> element("nav span.mx-2")
    |> render()
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
