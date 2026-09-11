defmodule PinchflatWeb.Pages.SystemHealthLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.SystemHealthLive

  describe "initial rendering" do
    test "shows health cards", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      assert html =~ "Database"
      assert html =~ "Job Queue"
      assert html =~ "Sources"
    end

    test "shows database stats", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      assert html =~ "Size"
      assert html =~ if(Pinchflat.Database.sqlite?(), do: "SQLite", else: "PostgreSQL")

      if Pinchflat.Database.sqlite?() do
        assert html =~ "WAL Size"
        assert html =~ "Page Count"
      end
    end

    test "shows queue stats", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      assert html =~ "Pending"
      assert html =~ "Executing"
      assert html =~ "Failed (24h)"
      assert html =~ "Completed (24h)"
    end

    test "shows source stats", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      assert html =~ "Total"
      assert html =~ "Enabled"
      assert html =~ "Never Indexed"
      assert html =~ "Stale"
    end
  end

  describe "stale sources" do
    test "shows stale sources section when sources haven't been indexed", %{conn: conn} do
      source = source_fixture(last_indexed_at: nil)

      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      assert html =~ "Sources Not Indexed Recently"
      assert html =~ source.custom_name
    end

    test "shows stale sources when last_indexed_at is old", %{conn: conn} do
      old_time = DateTime.utc_now() |> DateTime.add(-48, :hour)
      source = source_fixture(last_indexed_at: old_time)

      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      assert html =~ "Sources Not Indexed Recently"
      assert html =~ source.custom_name
    end

    test "does not show stale sources when recently indexed", %{conn: conn} do
      recent_time = DateTime.utc_now() |> DateTime.add(-1, :hour)
      source = source_fixture(last_indexed_at: recent_time)

      {:ok, _view, html} = live_isolated(conn, SystemHealthLive, session: %{})

      refute html =~ "Sources Not Indexed Recently"
      refute html =~ source.custom_name
    end
  end

  describe "user interactions" do
    test "refresh button updates the view", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, SystemHealthLive, session: %{})

      # Should not error
      html = view |> element("button[phx-click='refresh']") |> render_click()

      assert html =~ "Database"
    end
  end
end
