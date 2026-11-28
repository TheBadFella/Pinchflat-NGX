defmodule PinchflatWeb.SourceRemovedControllerTest do
  use PinchflatWeb.ConnCase

  import Mox
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Sources.SourceRemoval

  setup do
    stub(AppriseRunnerMock, :run, fn _servers, _opts -> {:error, :no_servers} end)
    :ok
  end

  test "the source page explains a removed source and offers the ways out", %{conn: conn} do
    source = source_fixture(%{collection_type: :playlist, custom_name: "Old Playlist"})
    {:ok, source} = SourceRemoval.mark_removed(source, "The playlist does not exist.")

    html = conn |> get(~p"/sources/#{source}") |> html_response(200)

    assert html =~ ~s(id="removed-source-notice")
    assert html =~ "YouTube no longer has this playlist"
    assert html =~ "The playlist does not exist."
    assert html =~ "Removed on YouTube"
    assert html =~ ~s(action="/sources/#{source.id}/check_removed")
    assert html =~ "Delete Source"
  end

  test "sources that were not removed show no notice", %{conn: conn} do
    source = source_fixture()

    refute conn |> get(~p"/sources/#{source}") |> html_response(200) =~ "removed-source-notice"
  end

  test "Check Again turns the source back on", %{conn: conn} do
    source = source_fixture()
    {:ok, source} = SourceRemoval.mark_removed(source, "This channel does not exist.")

    conn = post(conn, ~p"/sources/#{source}/check_removed")

    assert redirected_to(conn) == ~p"/sources/#{source}"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Checking"
    assert Sources.get_source!(source.id).enabled
  end
end
