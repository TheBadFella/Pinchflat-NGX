defmodule Pinchflat.Metadata.SourceDescriptionCapacityTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  test "metadata refresh preserves complete descriptions at and beyond the old limit" do
    source = source_fixture(%{custom_name_locked: true})

    for description <- [String.duplicate("a", 255), String.duplicate("a", 256), String.duplicate("日本語 Ω 🎥\n", 1_000)] do
      stub_metadata(description)
      assert :ok = perform_job(SourceMetadataStorageWorker, %{id: source.id})

      updated = Repo.preload(Repo.reload!(source), :metadata)
      assert updated.description == description
      assert updated.uuid == source.uuid
      assert updated.custom_name == source.custom_name
      assert updated.custom_name_locked

      assert {:ok, %{"description" => ^description}} =
               MetadataFileHelpers.read_compressed_metadata(updated.metadata.metadata_filepath)

      metadata_id = updated.metadata.id
      assert :ok = perform_job(SourceMetadataStorageWorker, %{id: source.id})
      assert Repo.preload(Repo.reload!(source), :metadata).metadata.id == metadata_id
    end
  end

  test "long remote description does not replace a locked description" do
    source = source_fixture(%{description: "Pinned description", description_locked: true})
    stub_metadata(String.duplicate("Ω", 1_000))
    assert :ok = perform_job(SourceMetadataStorageWorker, %{id: source.id})
    assert Repo.reload!(source).description == "Pinned description"
    assert Repo.reload!(source).description_locked
  end

  test "missing and empty descriptions preserve existing refresh semantics" do
    source = source_fixture(%{description: "Original description"})
    stub_metadata(nil)
    assert :ok = perform_job(SourceMetadataStorageWorker, %{id: source.id})
    assert Repo.reload!(source).description == "Original description"
    stub_metadata("")
    assert :ok = perform_job(SourceMetadataStorageWorker, %{id: source.id})
    assert Repo.reload!(source).description == nil
  end

  defp stub_metadata(description) do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
      _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, Jason.encode!(%{"description" => description})}
    end)
  end
end
