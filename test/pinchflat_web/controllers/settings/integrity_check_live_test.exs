defmodule PinchflatWeb.Settings.IntegrityCheckLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures

  alias Pinchflat.Settings.IntegrityCheckLive

  describe "initial rendering" do
    test "renders the button and both check modes", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, IntegrityCheckLive)

      assert html =~ "Check Integrity"
      assert html =~ "Quick Check"
      assert html =~ "Full Check"
    end

    test "shows no results before a check has been run", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, IntegrityCheckLive)

      refute html =~ "No problems found"
      refute html =~ "problem(s)"
    end
  end

  describe "running a check" do
    test "reports a clean quick check", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IntegrityCheckLive)

      render_click(view, "check", %{"mode" => "quick"})

      html = render(view)
      assert html =~ "No problems found"
      assert html =~ "Quick check completed at"
    end

    test "reports a clean full check", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IntegrityCheckLive)

      render_click(view, "check", %{"mode" => "full"})

      html = render(view)
      assert html =~ "No problems found"
      assert html =~ "Full check completed at"
    end

    test "falls back to a quick check for an unknown mode", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IntegrityCheckLive)

      render_click(view, "check", %{"mode" => "something-else"})

      assert render(view) =~ "Quick check completed at"
    end
  end

  describe "when the database has problems" do
    setup do
      media_item_fixture(title: "a title to index")
      corrupt_search_index()

      :ok
    end

    test "reports the findings verbatim", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IntegrityCheckLive)

      render_click(view, "check", %{"mode" => "quick"})

      html = render(view)
      assert html =~ "SQLite reported"
      assert html =~ "problem(s)"
      assert html =~ "media_items_search_index"
      refute html =~ "No problems found"
    end

    test "says nothing was changed and points at a manual repair", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IntegrityCheckLive)

      render_click(view, "check", %{"mode" => "quick"})

      html = render(view)
      assert html =~ "Nothing has been changed"
      assert html =~ "back up your database file"
    end

    test "notes that search index problems are rebuildable", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, IntegrityCheckLive)

      render_click(view, "check", %{"mode" => "quick"})

      assert render(view) =~ "can be rebuilt"
    end
  end
end
