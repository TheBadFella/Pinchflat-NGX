defmodule Pinchflat.SlowIndexing.IntakeTitleRegressionTest do
  use Pinchflat.DataCase
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers, as: Indexing
  alias Pinchflat.YoutubeBrowser.Intake

  defp intake_source do
    profile =
      media_profile_fixture(
        output_path_template: "{{ source_custom_name }}/{{ title }}.{{ ext }}",
        download_source_images: false
      )

    assert {:ok, :indexing} = Intake.download_video("probe_video", profile.id)
    Repo.get_by!(Source, collection_id: "probe_video", media_profile_id: profile.id)
  end

  defp metadata(source) do
    %{
      "id" => source.collection_id,
      "title" => "Indexed title",
      "ext" => "mp4",
      "duration" => 600,
      "original_url" => source.original_url,
      "upload_date" => "20261019",
      "filename" => "/tmp/test/media/YouTube Video probe_video/Indexed title.mp4"
    }
  end

  test "a manual rename during fetch controls prediction and download queueing" do
    source = intake_source()

    stub(YtDlpRunnerMock, :run, fn
      _, :get_media_attributes_for_collection, _, _, _ ->
        source |> Ecto.Changeset.change(custom_name: "User name") |> Repo.update!()
        {:ok, Jason.encode!(metadata(source))}

      _, :predict_filepath_from_metadata, opts, _, _ ->
        assert List.keyfind(opts, :output, 0) == {:output, "/tmp/test/media/User name/%(title)S.%(ext)S"}
        {:ok, Jason.encode!(%{"filename" => "/tmp/test/media/User name/Indexed title.mp4"})}
    end)

    assert [item] = Indexing.index_and_enqueue_download_for_media_items(source)
    assert Sources.get_source!(source.id).custom_name == "User name"
    assert item.predicted_media_filepath == "/tmp/test/media/User name/Indexed title.mp4"
    assert_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker, args: %{"id" => item.id})
  end

  test "failed prediction queues nothing and a retry converges" do
    source = intake_source()

    stub(YtDlpRunnerMock, :run, fn
      _, :get_media_attributes_for_collection, _, _, _ -> {:ok, Jason.encode!(metadata(source))}
      _, :predict_filepath_from_metadata, _, _, _ -> {:error, "probe renderer failure", 1}
    end)

    assert_raise MatchError, fn -> Indexing.index_and_enqueue_download_for_media_items(source) end
    assert Sources.get_source!(source.id).custom_name == "YouTube Video probe_video"
    refute Repo.get_by(MediaItem, source_id: source.id)
    refute_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker)

    stub(YtDlpRunnerMock, :run, fn
      _, :get_media_attributes_for_collection, _opts, _, _ ->
        {:ok, Jason.encode!(metadata(source))}

      _, :predict_filepath_from_metadata, opts, _, _ ->
        assert List.keyfind(opts, :output, 0) == {:output, "/tmp/test/media/Indexed title/%(title)S.%(ext)S"}
        {:ok, Jason.encode!(%{"filename" => "/tmp/test/media/Indexed title/Indexed title.mp4"})}
    end)

    assert [item] = Indexing.index_and_enqueue_download_for_media_items(Sources.get_source!(source.id))
    assert item.predicted_media_filepath == "/tmp/test/media/Indexed title/Indexed title.mp4"
  end

  test "retargeting during fetch must not import the old video into the new source" do
    source = intake_source()

    stub(YtDlpRunnerMock, :run, fn
      _, :get_media_attributes_for_collection, _, _, _ ->
        source
        |> Ecto.Changeset.change(collection_id: "new_video", original_url: "https://www.youtube.com/watch?v=new_video")
        |> Repo.update!()

        {:ok, Jason.encode!(metadata(source))}
    end)

    Indexing.index_and_enqueue_download_for_media_items(source)
    refute Repo.get_by(MediaItem, source_id: source.id, media_id: "probe_video")
    refute_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker)
    assert Sources.get_source!(source.id).last_indexed_at == nil
  end

  test "an ordinary unlocked standalone video retains metadata title refresh" do
    source =
      source_fixture(
        collection_type: :video,
        source_type: :video,
        collection_id: "probe_video",
        custom_name: "Previous title",
        collection_name: "Previous title",
        custom_name_locked: false,
        original_url: "https://www.youtube.com/watch?v=probe_video"
      )

    stub(YtDlpRunnerMock, :run, fn
      _, :get_source_details, _, _, _ ->
        {:ok,
         Jason.encode!(%{id: "probe_video", title: "Updated title", filename: "/tmp/test/media/Updated title.mp4"})}

      _, :get_source_metadata, _, _, _ ->
        {:ok, Jason.encode!(%{id: "probe_video", title: "Updated title"})}
    end)

    assert :ok = perform_job(Pinchflat.Metadata.SourceMetadataStorageWorker, %{id: source.id})
    assert Sources.get_source!(source.id).custom_name == "Updated title"
  end

  test "a metadata refresh preserves edits made while its fetch is running" do
    source =
      source_fixture(
        collection_type: :video,
        source_type: :video,
        collection_id: "probe_video",
        custom_name: "Previous title",
        collection_name: "Previous title",
        custom_name_locked: false,
        original_url: "https://www.youtube.com/watch?v=probe_video"
      )

    stub(YtDlpRunnerMock, :run, fn
      _, :get_source_details, _, _, _ ->
        {:ok,
         Jason.encode!(%{id: "probe_video", title: "Fetched title", filename: "/tmp/test/media/Fetched title.mp4"})}

      _, :get_source_metadata, _, _, _ ->
        source |> Ecto.Changeset.change(custom_name: "User's latest name") |> Repo.update!()
        {:ok, Jason.encode!(%{id: "probe_video", title: "Fetched title"})}
    end)

    assert :ok = perform_job(Pinchflat.Metadata.SourceMetadataStorageWorker, %{id: source.id})
    assert Sources.get_source!(source.id).custom_name == "User's latest name"
  end

  test "a metadata title cannot turn source_custom_name into parent directories" do
    source = intake_source()

    stub(YtDlpRunnerMock, :run, fn
      _, :get_media_attributes_for_collection, _, _, _ ->
        {:ok, Jason.encode!(Map.put(metadata(source), "title", "../../outside"))}

      _, :predict_filepath_from_metadata, opts, _, _ ->
        {:output, output} = List.keyfind(opts, :output, 0)
        {:ok, Jason.encode!(%{"filename" => Path.expand(output)})}
    end)

    Indexing.index_and_enqueue_download_for_media_items(source)
    source = Sources.get_source!(source.id) |> Repo.preload(:media_profile)
    output = Pinchflat.Downloading.DownloadOptionBuilder.build_output_path_for(source)
    assert String.starts_with?(Path.expand(output), "/tmp/test/media/")
  end
end
