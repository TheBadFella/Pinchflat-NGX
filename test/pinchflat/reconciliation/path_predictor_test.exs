defmodule Pinchflat.Reconciliation.PathPredictorTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Reconciliation.PathPredictor

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
