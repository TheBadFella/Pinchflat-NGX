defmodule Pinchflat.Sources.PlaylistFilesTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Sources.PlaylistFiles
  alias Pinchflat.Sources.PlaylistMembership

  setup do
    dir = Path.join(System.tmp_dir!(), "playlist-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    source = source_fixture(%{collection_type: :channel, playlist_files: true})
    {:ok, dir: dir, source: source}
  end

  test "writes one playlist file per playlist in playlist order", %{dir: dir, source: source} do
    a = downloaded(source, dir, "Talks/a.mp4", %{media_id: "a", title: "Alpha", duration_seconds: 61})
    b = downloaded(source, dir, "b.mp4", %{media_id: "b", title: "Beta"})
    media_item_fixture(%{source_id: source.id, media_id: "pending", media_filepath: nil})

    membership(source, "a", "PL1", "Talks", 0, 1)
    membership(source, "b", "PL1", "Talks", 0, 0)
    membership(source, "pending", "PL1", "Talks", 0, 2)
    membership(source, "a", "PL2", "Best of", 1, 0)

    assert {:ok, 2} = PlaylistFiles.sync(source)

    assert File.read!(Path.join(dir, "Talks.m3u")) ==
             Enum.join(
               ["#EXTM3U", "#PLAYLIST:Talks", PlaylistFiles.marker(source), "#EXTINF:-1,Beta", "b.mp4"] ++
                 ["#EXTINF:61,Alpha", "Talks/a.mp4"],
               "\n"
             ) <> "\n"

    assert File.read!(Path.join(dir, "Best of.m3u")) =~ "Talks/a.mp4"
    assert a.media_filepath =~ dir and b.media_filepath =~ dir
  end

  test "keeps two playlists with the same title apart", %{dir: dir, source: source} do
    downloaded(source, dir, "x.mp4", %{media_id: "x"})
    membership(source, "x", "PLone", "Same", 0, 0)
    membership(source, "x", "PLtwo", "Same", 1, 0)

    assert {:ok, 2} = PlaylistFiles.sync(source)
    assert File.exists?(Path.join(dir, "Same (PLone).m3u"))
    assert File.exists?(Path.join(dir, "Same (PLtwo).m3u"))
  end

  test "never replaces or removes playlist files it did not write", %{dir: dir, source: source} do
    downloaded(source, dir, "x.mp4", %{media_id: "x"})
    membership(source, "x", "PL1", "Mine", 0, 0)
    File.write!(Path.join(dir, "Mine.m3u"), "#EXTM3U\nhand-made.mp4\n")
    File.write!(Path.join(dir, "Other.m3u"), "#EXTM3U\nother.mp4\n")

    assert {:ok, 0} = PlaylistFiles.sync(source)
    assert File.read!(Path.join(dir, "Mine.m3u")) == "#EXTM3U\nhand-made.mp4\n"
    assert File.exists?(Path.join(dir, "Other.m3u"))
  end

  test "removes its files for playlists that are gone and when turned off", %{dir: dir, source: source} do
    downloaded(source, dir, "x.mp4", %{media_id: "x"})
    membership(source, "x", "PL1", "Old", 0, 0)
    assert {:ok, 1} = PlaylistFiles.sync(source)

    Repo.delete_all(PlaylistMembership)
    membership(source, "x", "PL2", "New", 0, 0)
    assert {:ok, 1} = PlaylistFiles.sync(source)
    refute File.exists?(Path.join(dir, "Old.m3u"))
    assert File.exists?(Path.join(dir, "New.m3u"))

    {:ok, source} = Sources.update_source(source, %{playlist_files: false})
    assert {:ok, 0} = PlaylistFiles.sync(source)
    refute File.exists?(Path.join(dir, "New.m3u"))
  end

  defp downloaded(source, dir, relative, attrs) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    media_item_fixture(Map.merge(%{source_id: source.id, media_filepath: path}, attrs))
  end

  defp membership(source, media_id, playlist_id, title, position, entry_index) do
    Repo.insert!(%PlaylistMembership{
      source_id: source.id,
      media_id: media_id,
      playlist_id: playlist_id,
      playlist_title: title,
      position: position,
      entry_index: entry_index
    })
  end
end
