defmodule Pinchflat.Media.RelinkTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.Relink

  setup do
    root = Path.join(System.tmp_dir!(), "relink-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, source: source_fixture()}
  end

  test "matches moved files by video ID and relinks their sidecars", %{root: root, source: source} do
    item = missing_item(source, %{media_id: "dQw4w9WgXcQ", title: "Never"})
    media = touch(root, "Moved/Never [dQw4w9WgXcQ].mkv")
    thumb = touch(root, "Moved/Never [dQw4w9WgXcQ].jpg")
    nfo = touch(root, "Moved/Never [dQw4w9WgXcQ].nfo")
    subtitle = touch(root, "Moved/Never [dQw4w9WgXcQ].en.srt")

    assert {:ok, [%{status: :matched, match: :video_id, new_path: ^media}]} = Relink.plan(source, root)
    assert {:ok, 1} = Relink.apply(source, [item.id], root)

    item = Repo.reload!(item)
    assert item.media_filepath == media
    assert item.thumbnail_filepath == thumb
    assert item.nfo_filepath == nfo
    assert item.subtitle_filepaths == [["en", subtitle]]
    assert File.exists?(media)
  end

  test "does not take an ID that is only part of a longer name", %{root: root, source: source} do
    missing_item(source, %{media_id: "abc123", title: "Something else"})
    touch(root, "video-xabc123y.mp4")

    assert {:ok, [%{status: :not_found}]} = Relink.plan(source, root)
  end

  test "uses an info.json sidecar, then a unique title", %{root: root, source: source} do
    by_info = missing_item(source, %{media_id: "infoID00001", title: "Renamed"})
    touch(root, "a/episode 1.mp4")
    File.write!(Path.join(root, "a/episode 1.info.json"), ~s({"id": "infoID00001"}))

    by_title = missing_item(source, %{media_id: "titleID0001", title: "Cats: The Movie"})
    touch(root, "b/Cats - The Movie.webm")

    assert {:ok, entries} = Relink.plan(source, root)
    assert %{match: :info_json, status: :matched} = Enum.find(entries, &(&1.media_item.id == by_info.id))
    assert %{match: :title, status: :matched} = Enum.find(entries, &(&1.media_item.id == by_title.id))
  end

  test "leaves items with several candidates unchanged", %{root: root, source: source} do
    item = missing_item(source, %{media_id: "dupID000001"})
    touch(root, "one/x [dupID000001].mp4")
    touch(root, "two/x [dupID000001].mp4")

    assert {:ok, [%{status: :ambiguous, candidates: [_, _]}]} = Relink.plan(source, root)
    assert {:ok, 0} = Relink.apply(source, [item.id], root)
    assert Repo.reload!(item).media_filepath == item.media_filepath
  end

  test "never reuses a path recorded for another item", %{root: root, source: source} do
    taken = touch(root, "x [ownID00001].mp4")
    media_item_fixture(%{source_id: source.id, media_filepath: taken})
    missing_item(source, %{media_id: "ownID00001"})

    assert {:ok, [%{status: :not_found}]} = Relink.plan(source, root)
  end

  test "only changes the items that were selected", %{root: root, source: source} do
    chosen = missing_item(source, %{media_id: "chosen00001"})
    skipped = missing_item(source, %{media_id: "skipped0001"})
    touch(root, "c [chosen00001].mp4")
    touch(root, "s [skipped0001].mp4")

    assert {:ok, 1} = Relink.apply(source, [chosen.id], root)
    assert Repo.reload!(skipped).media_filepath == skipped.media_filepath
  end

  defp missing_item(source, attrs) do
    media_item_fixture(
      Map.merge(%{source_id: source.id, media_filepath: "/tmp/gone/#{System.unique_integer([:positive])}.mp4"}, attrs)
    )
  end

  defp touch(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end
end
