defmodule Pinchflat.Reconciliation.PathPredictorTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Reconciliation.PathPredictor
  alias Pinchflat.Utils.FilesystemUtils

  setup do
    media_item = downloaded_media_item_with_stored_metadata()

    {:ok, media_item: media_item}
  end

  describe "predict_media_filepath/1" do
    test "renders the filename offline via --load-info-json", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn url, action, opts, ot, addl ->
        assert url == media_item.original_url
        assert action == :predict_filepath_from_metadata
        assert :simulate in opts
        assert :skip_download in opts
        assert Keyword.has_key?(opts, :load_info_json)
        assert Keyword.has_key?(opts, :output)
        assert ot == "%(.{filename})j"
        assert Keyword.get(addl, :skip_sleep_interval)

        {:ok, ~s({"filename": "/downloads/new home/video.mp4"})}
      end)

      assert {:ok, "/downloads/new home/video.mp4"} = PathPredictor.predict_media_filepath(media_item)
    end

    test "substitutes the actual downloaded extension", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl ->
        {:ok, ~s({"filename": "/downloads/new home/video.webm"})}
      end)

      # The fixture's downloaded file is an .mp4
      assert {:ok, "/downloads/new home/video.mp4"} = PathPredictor.predict_media_filepath(media_item)
    end

    test "returns :no_metadata when the item has no stored metadata" do
      media_item = Repo.preload(media_item_with_attachments(), [:metadata, source: :media_profile])

      assert {:error, :no_metadata} = PathPredictor.predict_media_filepath(media_item)
    end

    test "normalizes runner errors", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl ->
        {:error, "big bad", 1}
      end)

      assert {:error, "big bad"} = PathPredictor.predict_media_filepath(media_item)
    end
  end

  describe "predict_media_filepath/1 with scoped yt-dlp config files" do
    setup do
      base_dir = Path.join(Application.get_env(:pinchflat, :extras_directory), "yt-dlp-configs")

      File.rm_rf(base_dir)
      on_exit(fn -> File.rm_rf(base_dir) end)

      {:ok, %{base_dir: base_dir}}
    end

    test "passes the source config file to the offline render", %{media_item: media_item, base_dir: base_dir} do
      source_filepath = Path.join(base_dir, "source-#{media_item.source_id}-config.txt")
      FilesystemUtils.write_p!(source_filepath, "--restrict-filenames")

      expect(YtDlpRunnerMock, :run, fn _url, :predict_filepath_from_metadata, opts, _ot, _addl ->
        assert opts[:output] == "/tmp/test/media/%(title)S.%(ext)S"
        assert {:config_locations, source_filepath} in opts
        {:ok, ~s({"filename": "/tmp/test/media/cleaned_name.mp4"})}
      end)

      assert {:ok, "/tmp/test/media/cleaned_name.mp4"} = PathPredictor.predict_media_filepath(media_item)
    end

    test "passes config files in the same order as the download options", %{media_item: media_item, base_dir: base_dir} do
      source = media_item.source
      media_profile = source.media_profile

      base_filepath = Path.join(base_dir, "base-config.txt")
      source_filepath = Path.join(base_dir, "source-#{source.id}-config.txt")
      media_item_filepath = Path.join(base_dir, "media-item-#{media_item.id}-config.txt")
      media_profile_filepath = Path.join(base_dir, "media-profile-#{media_profile.id}-config.txt")

      for filepath <- [base_filepath, source_filepath, media_item_filepath, media_profile_filepath] do
        FilesystemUtils.write_p!(filepath, "--restrict-filenames")
      end

      expected_order = [
        {:config_locations, base_filepath},
        {:config_locations, media_profile_filepath},
        {:config_locations, source_filepath},
        {:config_locations, media_item_filepath}
      ]

      expect(YtDlpRunnerMock, :run, fn _url, :predict_filepath_from_metadata, opts, _ot, _addl ->
        assert Enum.filter(opts, &match?({:config_locations, _}, &1)) == expected_order
        {:ok, ~s({"filename": "/tmp/test/media/cleaned_name.mp4"})}
      end)

      assert {:ok, "/tmp/test/media/cleaned_name.mp4"} = PathPredictor.predict_media_filepath(media_item)

      # The download build must produce the identical config list, so the two
      # cannot drift apart.
      {:ok, download_options} = DownloadOptionBuilder.build(media_item)

      assert Enum.filter(download_options, &match?({:config_locations, _}, &1)) == expected_order
    end

    test "omits config options when no config files exist", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, :predict_filepath_from_metadata, opts, _ot, _addl ->
        refute Enum.any?(opts, &match?({:config_locations, _}, &1))
        {:ok, ~s({"filename": "/tmp/test/media/video.mp4"})}
      end)

      assert {:ok, "/tmp/test/media/video.mp4"} = PathPredictor.predict_media_filepath(media_item)
    end
  end

  describe "predict_series_directory/1" do
    test "derives the series directory from the rendered filepath", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl ->
        {:ok, ~s({"filename": "/downloads/Cool Channel/Season 1/video.mp4"})}
      end)

      assert {:ok, "/downloads/Cool Channel"} = PathPredictor.predict_series_directory(media_item)
    end

    test "returns an error when the directory can't be determined", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, fn _url, _action, _opts, _ot, _addl ->
        {:ok, ~s({"filename": "/downloads/video.mp4"})}
      end)

      assert {:error, :indeterminable} = PathPredictor.predict_series_directory(media_item)
    end
  end

  test "Shorts media predictions use Shorts paths while series roots use primary paths", %{media_item: item} do
    profile = %{
      item.source.media_profile
      | output_path_template: "Channel/{{ series_root }}/Season 1/{{ title }}.{{ ext }}",
        output_path_template_shorts: "Channel/Shorts/{{ title }}.{{ ext }}"
    }

    item = %{item | short_form_content: true, source: %{item.source | media_profile: profile}}

    expect(YtDlpRunnerMock, :run, fn _, _, opts, _, _ ->
      assert opts[:output] == "/tmp/test/media/Channel/Shorts/%(title)S.%(ext)S"
      {:ok, ~s({"filename":"/tmp/test/media/Channel/Shorts/short.mp4"})}
    end)

    assert {:ok, "/tmp/test/media/Channel/Shorts/short.mp4"} = PathPredictor.predict_media_filepath(item)

    expect(YtDlpRunnerMock, :run, fn _, _, opts, _, _ ->
      refute String.contains?(opts[:output], "Shorts")
      assert String.contains?(opts[:output], "Season 1")
      {:ok, ~s({"filename":"/tmp/test/media/Channel/Season 1/short.mp4"})}
    end)

    assert {:ok, "/tmp/test/media/Channel"} = PathPredictor.predict_series_directory(item)
  end

  test "offline reconciliation retains the profile's quality selection", %{media_item: item} do
    profile = %{item.source.media_profile | preferred_resolution: :audio}
    item = %{item | source: %{item.source | media_profile: profile}}

    expect(YtDlpRunnerMock, :run, fn _, _, opts, _, _ ->
      assert :extract_audio in opts
      assert opts[:format] == "bestaudio/best"
      {:ok, ~s({"filename":"/tmp/test/media/audio.m4a"})}
    end)

    assert {:ok, "/tmp/test/media/audio.mp4"} = PathPredictor.predict_media_filepath(item)
  end

  defp downloaded_media_item_with_stored_metadata do
    media_item = Repo.preload(media_item_with_attachments(), :metadata)

    metadata_filepath =
      MetadataFileHelpers.compress_and_store_metadata_for(media_item, %{
        "id" => media_item.media_id,
        "title" => media_item.title,
        "upload_date" => "20240101"
      })

    {:ok, media_item} =
      Media.update_media_item(media_item, %{
        metadata: %{metadata_filepath: metadata_filepath, thumbnail_filepath: media_item.thumbnail_filepath}
      })

    Repo.preload(media_item, [:metadata, source: :media_profile], force: true)
  end
end
