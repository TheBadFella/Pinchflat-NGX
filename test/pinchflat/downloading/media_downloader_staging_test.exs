defmodule Pinchflat.Downloading.MediaDownloaderStagingTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Downloading.MediaDownloader

  setup do
    media_root = Path.join(System.tmp_dir!(), "pinchyt-downloader-media-#{System.unique_integer([:positive])}")
    staging_root = Path.join(System.tmp_dir!(), "pinchyt-downloader-staging-#{System.unique_integer([:positive])}")
    original_media_root = Application.get_env(:pinchflat, :media_directory)
    original_staging_root = Application.get_env(:pinchflat, :download_staging_directory)
    original_disk_checker = Application.get_env(:pinchflat, :disk_space_checker)

    File.mkdir_p!(media_root)
    File.mkdir_p!(staging_root)
    Application.put_env(:pinchflat, :media_directory, media_root)
    Application.put_env(:pinchflat, :download_staging_directory, staging_root)
    stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 1_000_000} end)

    on_exit(fn ->
      Application.put_env(:pinchflat, :media_directory, original_media_root)
      Application.put_env(:pinchflat, :download_staging_directory, original_staging_root)
      Application.put_env(:pinchflat, :disk_space_checker, original_disk_checker)
      File.rm_rf!(media_root)
      File.rm_rf!(staging_root)
    end)

    media_item = media_item_fixture(%{title: "Staged download", media_filepath: nil})

    {:ok, media_item: media_item, staging_root: staging_root}
  end

  test "transfers completed artifacts before persisting final paths", %{
    media_item: media_item,
    staging_root: staging_root
  } do
    expect(YtDlpRunnerMock, :run, 3, fn
      _url, :get_downloadable_status, _opts, _output_template, _addl_opts ->
        {:ok, "{}"}

      _url, :download, opts, _output_template, _addl_opts ->
        output_template = Keyword.fetch!(opts, :output)
        artifact_directory = Path.dirname(output_template)
        media_filepath = Path.join(artifact_directory, "video.mp4")
        infojson_filepath = Path.join(artifact_directory, "video.info.json")
        subtitle_filepath = Path.join(artifact_directory, "video.en.srt")
        thumbnail_filepath = Path.join(artifact_directory, "video.jpg")

        Enum.each(
          [
            {media_filepath, "video"},
            {infojson_filepath, "{}"},
            {subtitle_filepath, "subtitles"},
            {thumbnail_filepath, "thumbnail"}
          ],
          fn {filepath, contents} ->
            File.mkdir_p!(Path.dirname(filepath))
            File.write!(filepath, contents)
          end
        )

        metadata =
          render_parsed_metadata(:media_metadata)
          |> Map.merge(%{
            "filepath" => media_filepath,
            "infojson_filename" => infojson_filepath,
            "requested_subtitles" => %{"en" => %{"filepath" => subtitle_filepath}},
            "thumbnails" => [%{"filepath" => thumbnail_filepath}]
          })

        {:ok, Phoenix.json_library().encode!(metadata)}

      _url, :download_thumbnail, _opts, _output_template, _addl_opts ->
        {:ok, ""}
    end)

    assert {:ok, updated_media_item} = MediaDownloader.download_for_media_item(media_item)
    assert File.exists?(updated_media_item.media_filepath)
    assert String.starts_with?(updated_media_item.media_filepath, Application.get_env(:pinchflat, :media_directory))
    assert File.ls!(staging_root) == []
  end

  test "cleans an item staging directory after yt-dlp failure without updating the database", %{
    media_item: media_item,
    staging_root: staging_root
  } do
    expect(YtDlpRunnerMock, :run, 2, fn
      _url, :get_downloadable_status, _opts, _output_template, _addl_opts ->
        {:ok, "{}"}

      _url, :download, _opts, _output_template, _addl_opts ->
        {:error, "temporary transfer failure", 1}
    end)

    assert {:error, :download_failed, "temporary transfer failure"} =
             MediaDownloader.download_for_media_item(media_item)

    assert Repo.reload!(media_item).media_filepath == nil
    assert File.ls!(staging_root) == []
  end
end
