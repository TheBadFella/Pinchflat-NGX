defmodule Pinchflat.Database.LibraryContractTest do
  use Pinchflat.DataCase, async: false
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.MediaMetadata
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Tasks.Task

  test "search follows insert, update and delete on the selected adapter" do
    item = media_item_fixture(%{title: "original201word", description: "description201word"})
    assert Enum.any?(Media.search("original201word"), &(&1.id == item.id))
    assert {:ok, updated} = Media.update_media_item(item, %{title: "replacement201word", description: nil})
    assert Media.search("original201word") == []
    assert Media.search("description201word") == []
    assert Enum.any?(Media.search("replacement201word"), &(&1.id == item.id))
    assert {:ok, _} = Media.delete_media_item(updated)
    assert Media.search("replacement201word") == []
  end

  test "primary, foreign and media uniqueness failures leave rows intact" do
    source = source_fixture(%{enabled: false})
    first = media_item_fixture(%{source_id: source.id})
    second = media_item_fixture(%{source_id: source.id})

    for sql <- [
          "UPDATE media_items SET id = #{second.id} WHERE id = #{first.id}",
          "UPDATE media_items SET source_id = 2147483647 WHERE id = #{first.id}",
          "UPDATE media_items SET media_id = (SELECT media_id FROM media_items WHERE id = #{first.id}) WHERE id = #{second.id}"
        ] do
      assert {:error, _} = Repo.query(sql)
      assert Repo.get!(MediaItem, first.id).source_id == source.id
      assert Repo.get!(MediaItem, second.id).media_id == second.media_id
    end
  end

  test "protected parent deletion and application cascades preserve referential integrity" do
    source = source_fixture(%{enabled: false, metadata: %{metadata_filepath: "/owned-contract201-source.json.gz"}})
    item = media_item_with_metadata(%{source_id: source.id})
    job = Pinchflat.JobFixtures.job_fixture()
    {:ok, task} = Pinchflat.Tasks.create_task(job, item)
    assert Repo.get(SourceMetadata, source.metadata.id)
    assert Repo.get(MediaMetadata, item.metadata.id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(source) end
    assert Repo.get!(MediaItem, item.id).source_id == source.id
    assert {:ok, _} = Pinchflat.Sources.delete_source(source)
    refute Repo.get(MediaItem, item.id)
    refute Repo.get(SourceMetadata, source.metadata.id)
    refute Repo.get(MediaMetadata, item.metadata.id)
    refute Repo.get(Task, task.id)
  end
end
