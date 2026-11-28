defmodule Pinchflat.Downloading.ResolutionUpgradeWorkerTest do
  use Pinchflat.DataCase

  import Mox
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.ResolutionUpgradeWorker
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Sources.SourceActions

  setup :verify_on_exit!

  setup do
    profile = media_profile_fixture(%{preferred_resolution: :"2160p"})
    {:ok, source: source_fixture(%{media_profile_id: profile.id})}
  end

  test "re-downloads only videos where a resolution closer to the preference is now offered", %{source: source} do
    closer_offered = downloaded_item(source, %{video_height: 1080})
    nothing_better = downloaded_item(source, %{video_height: 1080})
    already_at_target = downloaded_item(source, %{video_height: 2160})
    not_downloaded = media_item_fixture(%{source_id: source.id, media_filepath: nil})
    older_download = downloaded_item(source, %{video_height: nil})
    store_info(older_download, %{"height" => 720, "vcodec" => "avc1.4d401f"})

    offered = %{
      closer_offered.original_url => [1080, 1440],
      nothing_better.original_url => [720, 1080],
      older_download.original_url => [720, 1080]
    }

    expect(YtDlpRunnerMock, :run, 3, fn url, :check_formats, _opts, "%(.{formats})j", _addl ->
      formats = Enum.map(Map.fetch!(offered, url), &%{"height" => &1, "vcodec" => "avc1.640028"})
      {:ok, Phoenix.json_library().encode!(%{"formats" => formats})}
    end)

    perform_job(ResolutionUpgradeWorker, %{id: source.id})

    assert_enqueued(worker: MediaDownloadWorker, args: %{id: closer_offered.id, quality_upgrade?: true})
    assert_enqueued(worker: MediaDownloadWorker, args: %{id: older_download.id, quality_upgrade?: true})

    for item <- [nothing_better, already_at_target, not_downloaded] do
      refute_enqueued(worker: MediaDownloadWorker, args: %{id: item.id})
    end

    assert Repo.reload!(closer_offered).max_available_height == 1440
    assert Repo.reload!(older_download).video_height == 720
  end

  test "keeps a video when its formats cannot be checked", %{source: source} do
    item = downloaded_item(source, %{video_height: 1080})
    expect(YtDlpRunnerMock, :run, fn _url, :check_formats, _opts, _template, _addl -> {:error, "HTTP 429", 1} end)

    assert :ok = perform_job(ResolutionUpgradeWorker, %{id: source.id})
    refute_enqueued(worker: MediaDownloadWorker, args: %{id: item.id})
  end

  test "does nothing for audio-only profiles" do
    profile = media_profile_fixture(%{preferred_resolution: :audio})
    source = source_fixture(%{media_profile_id: profile.id})
    downloaded_item(source, %{video_height: 360})

    assert :ok = perform_job(ResolutionUpgradeWorker, %{id: source.id})
  end

  test "is queued from the source actions", %{source: source} do
    assert {:ok, _task} = SourceActions.kickoff(:upgrade_resolution, source)
    assert_enqueued(worker: ResolutionUpgradeWorker, args: %{id: source.id})
  end

  defp downloaded_item(source, attrs) do
    media_item_fixture(
      Map.merge(%{source_id: source.id, media_filepath: "/tmp/test/media/#{Ecto.UUID.generate()}.mp4"}, attrs)
    )
  end

  defp store_info(media_item, info) do
    path = MetadataFileHelpers.compress_and_store_metadata_for(media_item, info)

    Repo.insert!(%Pinchflat.Metadata.MediaMetadata{
      media_item_id: media_item.id,
      metadata_filepath: path,
      thumbnail_filepath: path
    })
  end
end
