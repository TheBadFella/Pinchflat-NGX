defmodule Pinchflat.Downloading.DownloadStagingTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.Downloading.DownloadStaging

  setup do
    media_root = Path.join(System.tmp_dir!(), "pinchyt-staging-media-#{System.unique_integer([:positive])}")
    staging_root = Path.join(System.tmp_dir!(), "pinchyt-staging-root-#{System.unique_integer([:positive])}")
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

    {:ok, media_root: media_root, staging_root: staging_root}
  end

  test "disabled configuration keeps the direct-download path unchanged" do
    Application.put_env(:pinchflat, :download_staging_directory, nil)

    assert DownloadStaging.configured_directory() == nil
    assert DownloadStaging.validate_configuration() == :disabled
    assert {:ok, nil} = DownloadStaging.prepare(1)
    assert {:ok, parsed} = DownloadStaging.transfer(%{"filepath" => "/downloads/video.mp4"}, nil)
    assert parsed["filepath"] == "/downloads/video.mp4"
  end

  test "validates an absolute writable root and rejects the media root", %{media_root: media_root} do
    Application.put_env(:pinchflat, :download_staging_directory, "relative/staging")
    assert DownloadStaging.validate_configuration() == {:error, :staging_root_must_be_absolute}

    Application.put_env(:pinchflat, :download_staging_directory, media_root)
    assert DownloadStaging.validate_configuration() == {:error, :staging_root_matches_media_root}
  end

  test "creates unique per-item directories inside the configured root", %{staging_root: staging_root} do
    assert {:ok, first} = DownloadStaging.prepare(10)
    assert {:ok, second} = DownloadStaging.prepare(10)
    assert first != second
    assert Path.dirname(first) == staging_root
    assert Path.dirname(second) == staging_root
    assert File.dir?(first)
    assert File.dir?(second)

    DownloadStaging.cleanup(first)
    DownloadStaging.cleanup(second)
    refute File.exists?(first)
    refute File.exists?(second)
  end

  test "moves the complete artifact set and rewrites final paths", %{media_root: media_root} do
    assert {:ok, staging_directory} = DownloadStaging.prepare(20)
    paths = create_artifacts(staging_directory)

    assert {:ok, transferred} = DownloadStaging.transfer(paths.metadata, staging_directory)
    assert transferred["filepath"] == Path.join(media_root, "Shows/Example/video.mp4")
    assert transferred["infojson_filename"] == Path.join(media_root, "Shows/Example/video.info.json")
    assert transferred["requested_subtitles"]["en"]["filepath"] == Path.join(media_root, "Shows/Example/video.en.srt")
    assert transferred["thumbnails"] == [%{"filepath" => Path.join(media_root, "Shows/Example/video.jpg")}]

    Enum.each(paths.destination_files, fn filepath -> assert File.exists?(filepath) end)
    Enum.each(paths.source_files, fn filepath -> refute File.exists?(filepath) end)
    DownloadStaging.cleanup(staging_directory)
    refute File.exists?(staging_directory)
  end

  test "uses copy to a destination temporary name before the final rename", %{media_root: media_root} do
    assert {:ok, staging_directory} = DownloadStaging.prepare(21)
    paths = create_artifacts(staging_directory)

    assert {:ok, transferred} = DownloadStaging.transfer(paths.metadata, staging_directory, transfer_mode: :copy)
    assert File.exists?(transferred["filepath"])
    assert File.read!(transferred["filepath"]) == "video"
    refute Enum.any?(Path.wildcard(Path.join(media_root, "**/*.pinchyt-copy-*")))
    refute File.exists?(paths.metadata["filepath"])
  end

  test "rejects traversal and invalid identifiers without leaving files", %{staging_root: staging_root} do
    assert {:ok, staging_directory} = DownloadStaging.prepare(22)
    assert {:error, :path_escape} = DownloadStaging.output_path(staging_directory, "../outside/video.mp4")
    assert {:error, :invalid_media_item_id} = DownloadStaging.prepare("../22")

    outside_path = Path.join(staging_root, "../outside-video.mp4") |> Path.expand()
    assert {:error, :path_escape} = DownloadStaging.transfer(%{"filepath" => outside_path}, staging_directory)
    refute File.exists?(outside_path)
    DownloadStaging.cleanup(staging_directory)
  end

  test "requires the media artifact and cleans a failed attempt", %{staging_root: staging_root} do
    assert {:ok, staging_directory} = DownloadStaging.prepare(23)
    missing_media = Path.join(staging_directory, "missing/video.mp4")

    assert {:error, :missing_media_artifact} =
             DownloadStaging.transfer(%{"filepath" => missing_media}, staging_directory)

    DownloadStaging.cleanup(staging_directory)
    assert File.ls!(staging_root) == []
  end

  test "stale cleanup skips an active media item", %{staging_root: staging_root} do
    assert {:ok, active_directory} = DownloadStaging.prepare(24)
    assert {:ok, stale_directory} = DownloadStaging.prepare(25)
    unrelated_directory = Path.join(staging_root, "keep-me")
    File.mkdir_p!(unrelated_directory)

    assert :ok = DownloadStaging.cleanup_stale([24], stale_after_seconds: 0)
    assert File.dir?(active_directory)
    refute File.exists?(stale_directory)
    assert File.dir?(unrelated_directory)
  end

  test "returns a useful error when staging has no free space" do
    stub(DiskSpaceCheckerMock, :available_bytes, fn _path -> {:ok, 0} end)

    assert {:error, :insufficient_staging_space} = DownloadStaging.prepare(26)
  end

  defp create_artifacts(staging_directory) do
    source_files =
      Enum.map(
        [
          "Shows/Example/video.mp4",
          "Shows/Example/video.info.json",
          "Shows/Example/video.en.srt",
          "Shows/Example/video.jpg"
        ],
        &Path.join(staging_directory, &1)
      )

    Enum.zip(source_files, ["video", "{}", "subtitles", "thumbnail"])
    |> Enum.each(fn {filepath, contents} ->
      File.mkdir_p!(Path.dirname(filepath))
      File.write!(filepath, contents)
    end)

    metadata = %{
      "filepath" => Enum.at(source_files, 0),
      "infojson_filename" => Enum.at(source_files, 1),
      "requested_subtitles" => %{"en" => %{"filepath" => Enum.at(source_files, 2)}},
      "thumbnails" => [%{"filepath" => Enum.at(source_files, 3)}]
    }

    destination_files =
      Enum.map(source_files, fn filepath ->
        filepath
        |> Path.relative_to(staging_directory)
        |> then(&Path.join(Application.get_env(:pinchflat, :media_directory), &1))
      end)

    %{metadata: metadata, source_files: source_files, destination_files: destination_files}
  end
end
