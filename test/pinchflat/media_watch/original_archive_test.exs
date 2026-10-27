defmodule Pinchflat.MediaWatch.OriginalArchiveTest do
  use Pinchflat.DataCase

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.OriginalArchive

  setup do
    watch_id = System.unique_integer([:positive])
    directory = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "archive-#{watch_id}")
    File.mkdir_p!(directory)

    on_exit(fn -> File.rm_rf(OriginalArchive.root()) end)

    %{watch: %Watch{id: watch_id}, directory: directory}
  end

  test "publishes the main file and present sidecars with a verifiable manifest", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "original media bytes")
    thumbnail = write!(Path.join(directory, "talk.jpg"), "thumbnail bytes")
    subtitle = write!(Path.join(directory, "talk.en.vtt"), "subtitle bytes")
    nfo = write!(Path.join(directory, "talk.nfo"), "<movie/>")

    item =
      media_item(%{
        media_filepath: main,
        thumbnail_filepath: thumbnail,
        subtitle_filepaths: [["en", subtitle]],
        nfo_filepath: nfo
      })

    assert {:ok, %{manifest_path: manifest_path, manifest: manifest}} =
             OriginalArchive.publish(watch, item)

    assert manifest_path == OriginalArchive.relative_manifest_path(watch.id)
    assert Enum.map(manifest["files"], & &1["role"]) == ["media", "thumbnail", "nfo", "subtitle-en"]

    assert File.read!(Path.join(OriginalArchive.archive_directory(watch.id), "media.mkv")) ==
             "original media bytes"

    assert {:ok, verified} = OriginalArchive.verify_relative(manifest_path, watch_id: watch.id)
    assert verified["watch_id"] == watch.id
  end

  test "a retry keeps the published archive instead of overwriting it", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "first artifact")
    item = media_item(%{media_filepath: main})

    assert {:ok, %{already_published: false}} = OriginalArchive.publish(watch, item)
    first_checksum = checksum(Path.join(OriginalArchive.archive_directory(watch.id), "media.mkv"))

    File.write!(main, "replacement artifact")

    assert {:ok, %{already_published: true}} = OriginalArchive.publish(watch, item)
    assert checksum(Path.join(OriginalArchive.archive_directory(watch.id), "media.mkv")) == first_checksum
  end

  test "fails closed when the main media is missing", %{watch: watch, directory: directory} do
    item = media_item(%{media_filepath: Path.join(directory, "missing.mp4")})

    assert {:error, :missing_main_media} = OriginalArchive.publish(watch, item)
    refute File.exists?(OriginalArchive.archive_directory(watch.id))
  end

  test "records a missing optional sidecar and ignores blank paths", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "bytes")

    item =
      media_item(%{
        media_filepath: main,
        thumbnail_filepath: Path.join(directory, "missing.jpg"),
        metadata_filepath: "",
        nfo_filepath: nil
      })

    assert {:ok, %{manifest: manifest}} = OriginalArchive.publish(watch, item)
    assert manifest["absent_roles"] == ["thumbnail"]
    assert Enum.map(manifest["files"], & &1["role"]) == ["media"]
  end

  test "rejects a symlinked source", %{watch: watch, directory: directory} do
    target = write!(Path.join(directory, "target.mkv"), "bytes")
    link = Path.join(directory, "link.mkv")
    File.ln_s!(target, link)

    assert {:error, {:source_is_symlink, "media"}} =
             OriginalArchive.publish(watch, media_item(%{media_filepath: link}))
  end

  test "rejects a symlinked archive root before creating any copy", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "first artifact")
    File.ln_s!(directory, OriginalArchive.root())

    assert {:error, {:archive_root_unavailable, :symlink_path_component}} =
             OriginalArchive.publish(watch, media_item(%{media_filepath: main}))

    assert File.read!(main) == "first artifact"
    assert File.ls!(directory) == ["talk.mkv"]
  end

  test "rejects a symlinked manifest even when its target has valid contents", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "first artifact")
    assert {:ok, %{manifest_path: relative}} = OriginalArchive.publish(watch, media_item(%{media_filepath: main}))
    manifest = OriginalArchive.manifest_path(watch.id)
    safe_copy = Path.join(directory, "saved-manifest.json")
    File.cp!(manifest, safe_copy)
    File.rm!(manifest)
    File.ln_s!(safe_copy, manifest)

    assert {:error, :symlink_path_component} = OriginalArchive.verify_relative(relative, watch_id: watch.id)
  end

  test "does not overwrite a reserved empty archive directory", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "first artifact")
    File.mkdir_p!(OriginalArchive.archive_directory(watch.id))

    assert {:error, {:archive_conflict, _}} = OriginalArchive.publish(watch, media_item(%{media_filepath: main}))
    assert File.read!(main) == "first artifact"
  end

  test "verify detects a tampered archive file", %{watch: watch, directory: directory} do
    main = write!(Path.join(directory, "talk.mkv"), "bytes")
    item = media_item(%{media_filepath: main})

    assert {:ok, %{manifest_path: manifest_path}} = OriginalArchive.publish(watch, item)
    File.write!(Path.join(OriginalArchive.archive_directory(watch.id), "media.mkv"), "tampered")

    assert {:error, :manifest_verification_failed} = OriginalArchive.verify_relative(manifest_path)
  end

  test "resolves only managed relative manifest paths" do
    assert {:ok, absolute} = OriginalArchive.resolve_manifest_path(".pinchflat-originals/7/manifest.json")
    assert String.ends_with?(absolute, ".pinchflat-originals/7/manifest.json")

    assert {:error, :invalid_manifest_path} = OriginalArchive.resolve_manifest_path("/etc/manifest.json")
    assert {:error, :invalid_manifest_path} = OriginalArchive.resolve_manifest_path("other/7/manifest.json")

    assert {:error, :invalid_manifest_path} =
             OriginalArchive.resolve_manifest_path(".pinchflat-originals/../7/manifest.json")
  end

  test "cleanup_temporary removes only that watch's unpublished directories", %{watch: watch} do
    root = OriginalArchive.root()
    File.mkdir_p!(root)
    owned = Path.join(root, ".preparing-#{watch.id}-one")
    other = Path.join(root, ".preparing-#{watch.id + 1}-two")
    File.mkdir_p!(owned)
    File.mkdir_p!(other)

    assert :ok = OriginalArchive.cleanup_temporary(watch.id)
    refute File.exists?(owned)
    assert File.exists?(other)
  end

  defp media_item(attrs) do
    struct(
      %MediaItem{
        id: System.unique_integer([:positive]),
        uuid: Ecto.UUID.generate(),
        media_id: "media-#{System.unique_integer([:positive])}",
        subtitle_filepaths: []
      },
      attrs
    )
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp checksum(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end
end
