defmodule PinchflatWeb.CommandPaletteLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias PinchflatWeb.CommandPaletteLive

  defp search(view, query), do: render_hook(view, "search", %{"query" => query})

  test "mounts closed without querying the database", %{conn: conn} do
    handler = "palette-mount-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:pinchflat, :repo, :query],
      fn _, _, meta, _ -> send(test_pid, {:query, meta.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, _view, html} = live_isolated(conn, CommandPaletteLive)

    assert html =~ ~s(data-palette-dialog)
    assert html =~ "display: none"
    refute_received {:query, _}
  end

  test "finds media with links, dates and download status", %{conn: conn} do
    source = source_fixture(%{custom_name: "Slow Kitchen"})

    downloaded =
      media_item_fixture(%{
        source_id: source.id,
        title: "Sourdough bread from scratch",
        media_filepath: "/tmp/bread.mp4",
        uploaded_at: ~U[2026-11-18 10:00:00Z],
        media_downloaded_at: ~U[2026-11-19 10:00:00Z]
      })

    pending = media_item_fixture(%{source_id: source.id, title: "Quick bread rolls", media_filepath: nil})

    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    html = search(view, "bread")

    assert html =~ ~s(href="/sources/#{source.id}/media/#{downloaded.id}")
    assert html =~ ~s(href="/sources/#{source.id}/media/#{pending.id}")
    assert html =~ "Slow Kitchen"
    assert html =~ "published"
    assert html =~ "downloaded"
    assert html =~ "Not downloaded"
    assert html =~ "See all media results for &quot;bread&quot;"
    assert html =~ ~s(href="/search?q=bread&amp;source_names=true")
  end

  test "url-encodes the see-all link", %{conn: conn} do
    media_item_fixture(%{title: "Rock and roll"})

    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)

    assert search(view, "rock and") =~ ~s(href="/search?q=rock+and&amp;source_names=true")
  end

  test "a one-character query skips media but still matches pages", %{conn: conn} do
    media_item_fixture(%{title: "A video"})

    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    html = search(view, "a")

    assert html =~ "Type at least 2 characters to search media."
    refute html =~ "See all media results"
    assert html =~ ~s(href="/sources/new")
  end

  test "finds sources and media profiles", %{conn: conn} do
    source = source_fixture(%{custom_name: "Archive Channel"})
    profile = media_profile_fixture(%{name: "Archive 4K"})

    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    html = search(view, "archive")

    assert html =~ ~s(href="/sources/#{source.id}")
    assert html =~ ~s(href="/media_profiles/#{profile.id}")
  end

  test "sources come first and channel names find their media", %{conn: conn} do
    source = source_fixture(%{custom_name: "Bread Channel"})
    item = media_item_fixture(%{source_id: source.id, title: "Sourdough basics"})
    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)

    html = search(view, "bread")
    assert [{source_position, _}] = :binary.matches(html, ~s(aria-label="Sources"))
    assert [{media_position, _}] = :binary.matches(html, ~s(aria-label="Media"))
    assert source_position < media_position
    assert html =~ ~s(href="/sources/#{source.id}/media/#{item.id}")
  end

  test "single videos appear once in Everything and remain searchable as sources", %{conn: conn} do
    source = source_fixture(%{custom_name: "Single Bread Video", collection_type: :video})
    item = media_item_fixture(%{source_id: source.id, title: "Single Bread Video"})
    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)

    html = search(view, "bread")
    assert html =~ ~s(href="/sources/#{source.id}/media/#{item.id}")
    refute html =~ ~s(href="/sources/#{source.id}")

    html = view |> element(~s(button[phx-value-scope="sources"])) |> render_click()
    assert html =~ ~s(href="/sources/#{source.id}")
  end

  test "whitespace preserves results and title text, and clearing restores navigation", %{conn: conn} do
    source_fixture(%{custom_name: "Hot Bread Today"})
    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)

    for query <- ["bre", "bre ", "bre"] do
      html = search(view, query)
      assert html =~ ~s(Hot <mark class="theme-palette-mark">Bre</mark>ad Today)
    end

    html = search(view, "")
    assert html =~ "Go to"
    refute html =~ ~s(href="/")
    refute html =~ ~s(href="/activity")
  end

  test "the media scope shows only media", %{conn: conn} do
    source = source_fixture(%{custom_name: "Bread Club"})
    media_item_fixture(%{source_id: source.id, title: "Bread basics"})

    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    search(view, "bread")
    html = view |> element(~s(button[phx-value-scope="media"])) |> render_click()

    assert html =~ "basics"
    refute html =~ ~s(href="/sources/#{source.id}")
  end

  test "explains when nothing matches", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    html = search(view, "zzzq")

    assert html =~ "Nothing matches &quot;zzzq&quot;"
    assert html =~ ~s(href="/browse")
  end

  test "escapes highlighted titles", %{conn: conn} do
    media_item_fixture(%{title: "<script>alert(1)</script> bread"})

    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    html = search(view, "bread")

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end

  test "reset clears the query and results", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, CommandPaletteLive)
    search(view, "zzzq")

    html = render_hook(view, "reset", %{})

    refute html =~ "Nothing matches"
  end

  describe "highlight_parts/2" do
    test "marks the first case-insensitive match" do
      assert CommandPaletteLive.highlight_parts("Bread and bread", "BREAD") == [
               {"Bread", true},
               {" and bread", false}
             ]
    end

    test "returns the whole text when there is no match or the query is blank" do
      assert CommandPaletteLive.highlight_parts("Bread", "zz") == [{"Bread", false}]
      assert CommandPaletteLive.highlight_parts("Bread", " ") == [{"Bread", false}]
    end
  end
end
