defmodule PinchflatWeb.SourceRelinkControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  setup do
    root = Application.get_env(:pinchflat, :media_directory)
    dir = Path.join(root, "relink-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "previews moved files and updates only the selected paths", %{conn: conn, dir: dir} do
    source = source_fixture()
    item = media_item_fixture(%{source_id: source.id, media_id: "ctrlID00001", media_filepath: "/tmp/gone/a.mp4"})
    found = Path.join(dir, "A [ctrlID00001].mp4")
    File.write!(found, "")

    html = conn |> get(~p"/sources/#{source}/relink") |> html_response(200)
    assert html =~ "Relink Moved Files"
    assert html =~ found
    assert html =~ "Matched by the video ID in the file name"

    conn = post(conn, ~p"/sources/#{source}/relink", %{"media_item_ids" => [to_string(item.id)]})
    assert redirected_to(conn) == ~p"/sources/#{source}/relink"
    assert Repo.reload!(item).media_filepath == found
  end

  test "says when nothing is missing", %{conn: conn} do
    source = source_fixture()

    html = conn |> get(~p"/sources/#{source}/relink") |> html_response(200)
    assert html =~ "Every downloaded file for this source is where Pinchflat-ngx expects it."
  end
end
