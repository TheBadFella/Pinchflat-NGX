defmodule Pinchflat.Sources.SourceActionsTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources.SourceActions
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  describe "run/2" do
    test "queues Download Pending for every selected source and skips those with Download Media off" do
      first = source_fixture()
      second = source_fixture()
      paused = source_fixture(download_media: false)
      for source <- [first, second, paused], do: media_item_fixture(source_id: source.id, media_filepath: nil)

      assert {:ok, %{sources: 3, queued: 2, duplicates: 0, failed: 0, skipped: 1}} =
               SourceActions.run(:download_pending, ids([first, second, paused]))

      assert length(all_enqueued(worker: MediaDownloadWorker)) == 2
    end

    test "redownloads existing media with force, leaving prevented items alone" do
      source = source_fixture()
      media_item_fixture(source_id: source.id)
      media_item_fixture(source_id: source.id, prevent_download: true)

      assert {:ok, %{queued: 1}} = SourceActions.run(:redownload_existing, ids([source]))
      assert [%{args: %{"force" => true}}] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "forces an index, a metadata refresh and a file sync for each source" do
      sources = [source_fixture(), source_fixture()]

      assert {:ok, %{queued: 2}} = SourceActions.run(:force_index, ids(sources))
      assert {:ok, %{queued: 2}} = SourceActions.run(:refresh_metadata, ids(sources))
      assert {:ok, %{queued: 2}} = SourceActions.run(:sync_files, ids(sources))

      assert [%{args: %{"force" => true}}, _] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert length(all_enqueued(worker: SourceMetadataStorageWorker)) == 2
      assert length(all_enqueued(worker: FileSyncingWorker)) == 2
    end

    test "counts downloads that are already queued" do
      source = source_fixture()
      media_item_fixture(source_id: source.id)

      assert {:ok, %{queued: 1}} = SourceActions.run(:redownload_existing, ids([source]))
      assert {:ok, %{queued: 0, duplicates: 1}} = SourceActions.run(:redownload_existing, ids([source]))
    end

    test "rejects unknown actions and unavailable selections without queuing anything" do
      source = source_fixture()
      deleted = source_fixture(marked_for_deletion_at: DateTime.utc_now())

      assert {:error, :invalid_action} = SourceActions.run(:delete_everything, ids([source]))
      assert {:error, :unavailable_source} = SourceActions.run(:force_index, ids([source, deleted]))
      assert {:error, :invalid_selection} = SourceActions.run(:force_index, [])
      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end
  end

  defp ids(sources), do: Enum.map(sources, &to_string(&1.id))
end
