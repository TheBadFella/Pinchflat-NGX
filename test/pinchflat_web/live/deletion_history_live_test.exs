defmodule PinchflatWeb.DeletionHistoryLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mox
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media
  alias Pinchflat.Pages.DeletionHistoryLive
  alias Pinchflat.Sources

  setup do
    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    :ok
  end

  test "shows an empty state", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, DeletionHistoryLive)

    assert html =~ "No deletions recorded yet"
  end

  test "lists deleted sources with their URL and deleted files with a source link", %{conn: conn} do
    deleted = source_fixture(%{custom_name: "Gone Channel", original_url: "https://www.youtube.com/@gone"})
    {:ok, _} = Sources.delete_source(deleted)

    media_item = media_item_with_attachments(%{title: "Old Video"})
    {:ok, _} = Media.delete_media_files(media_item, %{}, reason: :retention)

    {:ok, _view, html} = live_isolated(conn, DeletionHistoryLive)

    assert html =~ "Gone Channel"
    assert html =~ "https://www.youtube.com/@gone"
    assert html =~ "You deleted it"
    assert html =~ "Old Video"
    assert html =~ "Retention period ended"
    assert html =~ ~s(href="/sources/#{media_item.source_id}")
  end

  test "the home page has a Deletions tab", %{conn: conn} do
    Pinchflat.Settings.set(onboarding: false)
    conn = get(conn, ~p"/?tab=deletions")

    assert html_response(conn, 200) =~ ~s(href="/?tab=deletions")
  end
end
