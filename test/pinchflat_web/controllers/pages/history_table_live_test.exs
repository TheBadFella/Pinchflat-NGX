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

  @all_time_range %{"range" => "custom", "from" => "2000-01-01", "to" => "2099-12-31"}

  describe "latest time range" do
    test "custom dates use the configured timezone across clock changes", %{conn: conn} do
      original_timezone = Application.fetch_env!(:pinchflat, :timezone)
      on_exit(fn -> Application.put_env(:pinchflat, :timezone, original_timezone) end)

      for {timezone, date, first, next} <- [
            {"America/New_York", "2024-03-10", ~U[2024-03-10 05:00:00Z], ~U[2024-03-11 04:00:00Z]},
            {"America/New_York", "2024-11-03", ~U[2024-11-03 04:00:00Z], ~U[2024-11-04 05:00:00Z]},
            {"America/Sao_Paulo", "2018-11-04", ~U[2018-11-04 03:00:00Z], ~U[2018-11-05 02:00:00Z]},
            {"America/Havana", "2020-11-01", ~U[2020-11-01 04:00:00Z], ~U[2020-11-02 05:00:00Z]}
          ] do
        Application.put_env(:pinchflat, :timezone, timezone)
        source = source_fixture()
        before = indexed_fixture(source, "Before local day", DateTime.add(first, -1))
        start = indexed_fixture(source, "Start of local day", first)
        last = indexed_fixture(source, "End of local day", DateTime.add(next, -1))
        outside = indexed_fixture(source, "Next local day", next)

        {:ok, view, _} =
          live_isolated(conn, HistoryTableLive,
            session: %{
              "media_state" => "latest",
              "latest_range" => %{"range" => "custom", "from" => date, "to" => date}
            }
          )

        assert render_element(view, "tbody") =~ start.title
        assert render_element(view, "tbody") =~ last.title
        refute render(view) =~ before.title
        refute render(view) =~ outside.title
        assert has_element?(view, "#latest-from-picker[title*='#{timezone}']")
        assert has_element?(view, "label[for=latest-from]", "From")
        refute render(view) =~ "(UTC)"
      end
    end

    test "default custom dates follow the configured timezone", %{conn: conn} do
      original_timezone = Application.fetch_env!(:pinchflat, :timezone)
      on_exit(fn -> Application.put_env(:pinchflat, :timezone, original_timezone) end)
      Application.put_env(:pinchflat, :timezone, "Pacific/Kiritimati")
      today = DateTime.now!("Pacific/Kiritimati") |> DateTime.to_date()

      {:ok, view, _} =
        live_isolated(conn, HistoryTableLive,
          session: %{"media_state" => "latest", "latest_range" => %{"range" => "custom"}}
        )

      assert has_element?(view, "#latest-to[value='#{today}']")
      assert has_element?(view, "#latest-from[value='#{Date.add(today, -6)}']")
    end

    test "defaults to 24 hours and offers one day, seven days and custom", %{conn: conn} do
      source = source_fixture()
      recent = indexed_fixture(source, "Found today", DateTime.add(DateTime.utc_now(), -3600))
      old = indexed_fixture(source, "Found two days ago", DateTime.add(DateTime.utc_now(), -2, :day))
      {:ok, view, _} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest"})
      assert has_element?(view, "button[value=day][aria-pressed=true]", "1 day")
      assert has_element?(view, "button[value=week]", "7 days")
      assert has_element?(view, "button[value=custom]", "Custom")
      assert render_element(view, "tbody") =~ recent.title
      refute render_element(view, "tbody") =~ old.title
    end

    test "seven days excludes older items and survives layout and grouping changes", %{conn: conn} do
      source = source_fixture()
      included = indexed_fixture(source, "Found this week", DateTime.add(DateTime.utc_now(), -6, :day))
      excluded = indexed_fixture(source, "Found last week", DateTime.add(DateTime.utc_now(), -8, :day))

      {:ok, view, _} =
        live_isolated(conn, HistoryTableLive,
          session: %{"media_state" => "latest", "latest_range" => %{"range" => "week"}}
        )

      view |> element("#latest-desktop-controls button[phx-value-grouping=source]") |> render_click()
      view |> element("#latest-desktop-controls button[phx-value-view=grid]") |> render_click()
      assert render_element(view, "article") =~ included.title
      refute render(view) =~ excluded.title
      assert has_element?(view, "button[value=week][aria-pressed=true]")
    end

    test "custom dates include both selected days and exclude the next midnight", %{conn: conn} do
      source = source_fixture()
      first = indexed_fixture(source, "Start boundary", ~U[2024-03-01 00:00:00Z])
      last = indexed_fixture(source, "End boundary", ~U[2024-03-02 23:59:59Z])
      excluded = indexed_fixture(source, "Outside range", ~U[2024-03-03 00:00:00Z])

      {:ok, view, _} =
        live_isolated(conn, HistoryTableLive,
          session: %{
            "media_state" => "latest",
            "latest_range" => %{"range" => "custom", "from" => "2024-03-01", "to" => "2024-03-02"}
          }
        )

      assert render_element(view, "tbody") =~ first.title
      assert render_element(view, "tbody") =~ last.title
      refute render(view) =~ excluded.title
      assert has_element?(view, "#latest-custom-range input[name=from][value='2024-03-01']")
      assert has_element?(view, "#latest-from[type=text]")
      assert has_element?(view, "button[aria-controls=latest-from-calendar]")
      refute has_element?(view, "#latest-custom-range input[type=date]")
    end

    test "rejects invalid and reversed custom dates without showing unfiltered history", %{conn: conn} do
      for from <- ["bad-date", "2024-03-04"] do
        {:ok, view, _} =
          live_isolated(conn, HistoryTableLive,
            session: %{
              "media_state" => "latest",
              "latest_range" => %{"range" => "custom", "from" => from, "to" => "2024-03-02"}
            }
          )

        assert render(view) =~ "Enter valid dates with From on or before To."
        assert render(view) =~ "No media indexed in this time frame."
      end
    end

    test "ranks source groups using only items inside the selected range", %{conn: conn} do
      first = source_fixture(custom_name: "First in range")
      second = source_fixture(custom_name: "Second in range")
      indexed_fixture(first, "Recent matching item", ~U[2024-03-02 12:00:00Z])
      indexed_fixture(second, "Older matching item", ~U[2024-03-01 12:00:00Z])
      outside = indexed_fixture(second, "Newer but outside", ~U[2024-03-03 12:00:00Z])

      {:ok, view, _} =
        live_isolated(conn, HistoryTableLive,
          session: %{
            "media_state" => "latest",
            "latest_range" => %{"range" => "custom", "from" => "2024-03-01", "to" => "2024-03-02"}
          }
        )

      view |> element("#latest-desktop-controls button[phx-value-grouping=source]") |> render_click()
      assert render_element(view, "section[data-source-id]:first-child h3") =~ first.custom_name
      refute render(view) =~ outside.title
    end
  end

  describe "latest tab" do
    test "shows item status in list and grid and refreshes job transitions", %{conn: conn} do
      source = source_fixture()

      items =
        for {label, attrs} <- [
              {"Pending", %{media_filepath: nil}},
              {"Downloaded", %{}},
              {"Prevented", %{media_filepath: nil, prevent_download: true}},
              {"Transient failure", %{media_filepath: nil, last_error: "Network", error_type: :transient}},
              {"Permanent failure",
               %{
                 media_filepath: nil,
                 last_error: "Unavailable",
                 error_type: :permanent,
                 prevent_download: true,
                 download_prevented_reason: :error
               }}
            ] do
          {label, media_item_fixture(Map.put(attrs, :source_id, source.id))}
        end

      queued = media_item_fixture(source_id: source.id, media_filepath: nil)
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(queued)

      {:ok, view, _} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      for {label, item} <- items do
        assert has_element?(view, "tbody [data-media-status='#{item.id}']", label)
      end

      assert has_element?(view, "tbody [data-media-status='#{queued.id}']", "Queued")
      view |> element("#latest-desktop-controls button[phx-value-view=grid]") |> render_click()

      for {label, item} <- items do
        assert has_element?(view, "article [data-media-status='#{item.id}']", label)
      end

      for {state, label} <- [{"executing", "Downloading"}, {"retryable", "Retrying"}] do
        Repo.update_all(from(j in Oban.Job, where: j.id == ^task.job_id), set: [state: state])
        send(view.pid, %{topic: "job:state", event: "change", payload: %{media_item_id: queued.id}})
        assert has_element?(view, "article [data-media-status='#{queued.id}']", label)
      end
    end

    test "groups sources by their latest indexed item before paginating", %{conn: conn} do
      first_source = source_fixture(custom_name: "Recently active")
      second_source = source_fixture(custom_name: "Other source")

      for index <- 1..12 do
        item = media_item_fixture(source_id: first_source.id, title: "First source item #{index}")
        indexed_at = if index == 1, do: ~U[2026-10-15 12:00:00Z], else: ~U[2020-01-01 00:00:00Z]
        Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [inserted_at: indexed_at])
      end

      other = media_item_fixture(source_id: second_source.id, title: "Other source item")
      Repo.update_all(from(m in MediaItem, where: m.id == ^other.id), set: [inserted_at: ~U[2025-01-01 00:00:00Z]])

      {:ok, view, _html} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      view |> element("#latest-desktop-controls button[phx-value-grouping=source]") |> render_click()
      assert has_element?(view, "section[data-source-id='#{first_source.id}'] h3", first_source.custom_name)
      refute has_element?(view, "section[data-source-id='#{second_source.id}']")
      assert render_element(view, "tbody tr:first-child") =~ "First source item 1"

      view |> element("button.pagination-next") |> render_click()
      assert has_element?(view, "section[data-source-id='#{first_source.id}']")
      assert has_element?(view, "section[data-source-id='#{second_source.id}']")
      assert render_element(view, "section[data-source-id]:first-child h3") =~ first_source.custom_name
      assert render_element(view, "section[data-source-id]:last-child h3") =~ second_source.custom_name

      view |> element("#latest-desktop-controls button[phx-value-grouping=latest]") |> render_click()
      assert pagination_text(view) == "Page 1 of 2"

      assert has_element?(view, "button.pagination-prev[type=button][disabled]")
      assert has_element?(view, "button.pagination-next[type=button]:not([disabled])")
      refute has_element?(view, "section[data-source-id]")
      assert render_element(view, "tbody tr:nth-child(2)") =~ other.title
    end

    test "switches list and grid independently of grouping and sorts cards", %{conn: conn} do
      source = source_fixture()
      older = media_item_fixture(source_id: source.id, title: "Older upload", uploaded_at: ~U[2020-01-01 00:00:00Z])
      newer = media_item_fixture(source_id: source.id, title: "Newer upload", uploaded_at: ~U[2026-01-01 00:00:00Z])

      {:ok, view, _html} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      assert has_element?(view, "button[phx-value-view=list][aria-pressed=true]")
      view |> element("#latest-desktop-controls button[phx-value-view=grid]") |> render_click()
      refute has_element?(view, "table")
      assert has_element?(view, "button[phx-value-view=grid][aria-pressed=true]")

      view |> element("#latest-sort") |> render_change(%{"sort_key" => "uploaded_at", "sort_direction" => "asc"})
      assert render_element(view, "article:first-child") =~ older.title
      view |> element("#latest-sort") |> render_change(%{"sort_key" => "uploaded_at", "sort_direction" => "desc"})
      assert render_element(view, "article:first-child") =~ newer.title

      view |> element("#latest-desktop-controls button[phx-value-grouping=source]") |> render_click()
      assert has_element?(view, "section[data-source-id='#{source.id}'] article")
      refute has_element?(view, "table")
      view |> element("#latest-desktop-controls button[phx-value-view=list]") |> render_click()
      assert has_element?(view, "section[data-source-id='#{source.id}'] table")
    end

    test "mobile sheet changes grouping and sort without losing the layout", %{conn: conn} do
      media_item_fixture()

      {:ok, view, _} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      assert has_element?(view, "dialog#latest-filter-sheet[aria-labelledby=latest-filter-title]")
      view |> element("#latest-mobile-controls button[phx-value-view=grid]") |> render_click()
      view |> element("#latest-filter-sheet button[phx-value-grouping=source]") |> render_click()
      view |> element("#latest-mobile-sort") |> render_change(%{"sort_key" => "uploaded_at", "sort_direction" => "asc"})

      assert has_element?(view, "#latest-mobile-summary", "By source")
      assert has_element?(view, "#latest-mobile-summary", "Upload date")
      assert has_element?(view, "#latest-mobile-summary", "Oldest first")
      assert has_element?(view, "button[phx-value-view=grid][aria-pressed=true]")
      refute has_element?(view, "table")
      assert has_element?(view, "#latest-mobile-custom-range input[name=range][value=custom]")
    end

    test "keeps controls available when empty and rejects unknown options", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      view |> element("#latest-desktop-controls button[phx-value-grouping=source]") |> render_click()
      view |> element("#latest-desktop-controls button[phx-value-view=grid]") |> render_click()
      render_click(view, "view_change", %{"view" => "invalid"})
      render_click(view, "grouping_change", %{"grouping" => "invalid"})
      render_change(view, "latest_sort", %{"sort_key" => "bad", "sort_direction" => "bad"})
      assert has_element?(view, "button[phx-value-view=grid][aria-pressed=true]")
      assert has_element?(view, "button[phx-value-grouping=source][aria-pressed=true]")
      assert render(view) =~ "No media indexed in this time frame."
    end

    test "shows all states across sources by indexed time, with source links", %{conn: conn} do
      first_source = source_fixture(custom_name: "First channel")
      second_source = source_fixture(custom_name: "Second channel")

      items =
        for {attrs, day} <- [
              {%{source_id: first_source.id, media_filepath: nil, title: "Recently indexed"}, 3},
              {%{source_id: second_source.id, title: "Already downloaded"}, 1},
              {%{
                 source_id: second_source.id,
                 media_filepath: nil,
                 prevent_download: true,
                 last_error: "Unavailable",
                 title: "Prevented item"
               }, 2}
            ] do
          item = media_item_fixture(Map.put(attrs, :uploaded_at, ~U[2024-06-01 00:00:00Z]))

          Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
            set: [inserted_at: DateTime.add(~U[2024-01-01 00:00:00Z], day, :day)]
          )

          item
        end

      [newest, oldest, middle] = items

      {:ok, view, _html} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      assert render_element(view, "tbody tr:nth-child(1)") =~ newest.title
      assert render_element(view, "tbody tr:nth-child(2)") =~ middle.title
      assert render_element(view, "tbody tr:nth-child(3)") =~ oldest.title
      assert has_element?(view, ~s(th[aria-sort="descending"] button), "Indexed At")

      for source <- [first_source, second_source] do
        assert has_element?(view, ~s(tbody a[href="/sources/#{source.id}"]), source.custom_name)
        assert has_element?(view, ~s(article a[href="/sources/#{source.id}"]), source.custom_name)
      end

      assert render_element(view, "article:first-child") =~ newest.title

      view |> element("th button", "Indexed At") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ oldest.title

      view |> element("th button", "Indexed At") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ newest.title
    end

    test "shows the shared empty state", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      assert html =~ "No media indexed in this time frame."
    end

    test "paginates equal indexed timestamps deterministically", %{conn: conn} do
      source = source_fixture()

      items =
        for index <- 1..12 do
          item = media_item_fixture(source_id: source.id, title: "Indexed item #{index}")

          Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
            set: [inserted_at: ~U[2024-01-01 00:00:00Z]]
          )

          item
        end

      {:ok, view, _html} =
        live_isolated(conn, HistoryTableLive, session: %{"media_state" => "latest", "latest_range" => @all_time_range})

      assert render_element(view, "tbody tr:first-child") =~ hd(items).title
      assert pagination_text(view) == "Page 1 of 2"

      view |> element("button.pagination-next") |> render_click()
      assert render_element(view, "tbody tr:first-child") =~ Enum.at(items, 10).title
      assert render_element(view, "tbody tr:last-child") =~ List.last(items).title
      assert pagination_text(view) == "Page 2 of 2"

      assert has_element?(view, "button.pagination-prev[type=button]:not([disabled])")
      assert has_element?(view, "button.pagination-next[type=button][disabled]")
    end
  end

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

      view |> element("button.pagination-next") |> render_click()
      assert pagination_text(view) == "Page 2 of 2"

      socket = %{assigns: %{sort_key: nil, sort_direction: :desc}}
      assert {:noreply, ^socket} = HistoryTableLive.handle_event("sort_update", %{"sort_key" => "not_a_field"}, socket)

      view |> element("th button", "Upload Date") |> render_click()
      assert pagination_text(view) == "Page 1 of 2"
    end
  end

  defp indexed_fixture(source, title, indexed_at) do
    item = media_item_fixture(source_id: source.id, title: title)
    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [inserted_at: indexed_at])
    item
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
