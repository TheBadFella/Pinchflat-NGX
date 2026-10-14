defmodule Pinchflat.Media.LocalImportTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.Media.LocalImport
  alias Pinchflat.Media.MediaItem

  setup do
    root = Path.join(System.tmp_dir!(), "local-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.fetch_env!(:pinchflat, :media_directory)
    Application.put_env(:pinchflat, :media_directory, root)

    on_exit(fn ->
      Application.put_env(:pinchflat, :media_directory, previous)
      File.rm_rf!(root)
    end)

    source = source_fixture(%{enabled: false})
    info = Path.join(root, "Episode.info.json")
    file = Path.join(root, "Episode.mkv")
    metadata = %{id: "episode123", title: "Existing Episode", upload_date: "20260102", channel_id: source.collection_id}
    File.write!(info, Jason.encode!(metadata))
    File.write!(file, "EXISTING_MEDIA_BYTES")
    %{root: root, source: source, info: info, media_file: file, metadata: metadata}
  end

  test "preview is read-only and import preserves bytes, records the file and queues nothing", ctx do
    assert {:ok, %{entries: [%{status: :ready}]} = preview} = LocalImport.preview(ctx.source.id, "")
    assert Repo.aggregate(MediaItem, :count) == 0
    jobs_before = Repo.aggregate(Oban.Job, :count)

    assert {:ok, %{imported: 1}} = LocalImport.apply_preview(ctx.source.id, "", preview.fingerprint)
    item = Repo.get_by!(MediaItem, media_id: "episode123", source_id: ctx.source.id)
    assert item.media_filepath == ctx.media_file
    assert item.metadata_filepath == ctx.info
    assert item.predicted_media_filepath == ctx.media_file
    assert item.media_size_bytes == 20
    assert item.media_downloaded_at
    assert item.prevent_culling
    assert File.read!(ctx.media_file) == "EXISTING_MEDIA_BYTES"
    assert Jason.decode!(File.read!(ctx.info)) == Map.new(ctx.metadata, fn {k, v} -> {to_string(k), v} end)
    assert Repo.aggregate(Oban.Job, :count) == jobs_before

    assert {:ok, %{entries: [%{status: :already_recorded}]} = again} = LocalImport.preview(ctx.source.id, "")
    assert {:ok, %{imported: 0}} = LocalImport.apply_preview(ctx.source.id, "", again.fingerprint)
    assert Repo.aggregate(MediaItem, :count) == 1
  end

  test "changed metadata invalidates the preview without inserting rows", ctx do
    {:ok, preview} = LocalImport.preview(ctx.source.id, "")
    File.write!(ctx.info, Jason.encode!(%{ctx.metadata | title: "Changed"}))
    assert {:error, :stale_preview} = LocalImport.apply_preview(ctx.source.id, "", preview.fingerprint)
    assert Repo.aggregate(MediaItem, :count) == 0
  end

  test "active sources cannot be previewed or silently paused by an apply", ctx do
    source = Repo.update!(Ecto.Changeset.change(ctx.source, enabled: true))
    assert {:error, :pause_source_first} = LocalImport.preview(source.id, "")
    assert {:error, :pause_source_first} = LocalImport.apply_preview(source.id, "", "bad")
    assert Repo.reload!(source).enabled
  end

  test "rejects outside folders and symlink traversal", ctx do
    assert {:error, :outside_downloads} = LocalImport.preview(ctx.source.id, "../")
    File.ln_s!(System.tmp_dir!(), Path.join(ctx.root, "outside"))
    assert {:error, :directory_unavailable} = LocalImport.preview(ctx.source.id, "outside")
    assert {:ok, %{entries: [_]}} = LocalImport.preview(ctx.source.id, "")
  end

  test "ambiguous media files and malformed metadata are reported", ctx do
    File.write!(Path.join(ctx.root, "Episode.mp4"), "SECOND_FILE")
    assert {:ok, %{entries: [%{status: :ambiguous_media}]}} = LocalImport.preview(ctx.source.id, "")
    File.write!(ctx.info, Jason.encode!(%{ctx.metadata | upload_date: "bad"}))
    assert {:ok, %{entries: [%{status: :invalid_metadata}]}} = LocalImport.preview(ctx.source.id, "")
  end

  test "does not guess source ownership or overwrite already downloaded items", ctx do
    File.write!(ctx.info, Jason.encode!(%{ctx.metadata | channel_id: "different-channel"}))
    assert {:ok, %{entries: [%{status: :source_mismatch}]}} = LocalImport.preview(ctx.source.id, "")

    item =
      media_item_fixture(%{
        source_id: ctx.source.id,
        media_id: "episode123",
        title: "Existing title",
        media_filepath: "/already/recorded.mkv"
      })

    assert {:ok, %{entries: [%{status: :already_recorded}]} = preview} = LocalImport.preview(ctx.source.id, "")
    assert {:ok, %{imported: 0}} = LocalImport.apply_preview(ctx.source.id, "", preview.fingerprint)
    assert Repo.reload!(item).media_filepath == "/already/recorded.mkv"
    assert Repo.reload!(item).title == "Existing title"
  end

  test "refuses a file already referenced by another source", ctx do
    media_item_fixture(%{media_filepath: ctx.media_file})
    assert {:ok, %{entries: [%{status: :path_already_used}]}} = LocalImport.preview(ctx.source.id, "")
  end

  test "changed files and duplicate IDs cannot replace another import", ctx do
    {:ok, preview} = LocalImport.preview(ctx.source.id, "")
    File.write!(ctx.media_file, "DIFFERENT_SIZE")
    assert {:error, :stale_preview} = LocalImport.apply_preview(ctx.source.id, "", preview.fingerprint)
    File.write!(Path.join(ctx.root, "Duplicate.info.json"), Jason.encode!(ctx.metadata))
    File.write!(Path.join(ctx.root, "Duplicate.mkv"), "DUPLICATE")
    assert {:ok, %{entries: entries} = duplicated} = LocalImport.preview(ctx.source.id, "")
    assert Enum.all?(entries, &(&1.status == :duplicate_media_id))
    assert {:ok, %{imported: 0}} = LocalImport.apply_preview(ctx.source.id, "", duplicated.fingerprint)
    assert Repo.aggregate(MediaItem, :count) == 0
  end

  test "executing source tasks block the import even when the source is paused", ctx do
    job = Pinchflat.JobFixtures.job_fixture() |> Ecto.Changeset.change(state: "executing") |> Repo.update!()
    Pinchflat.TasksFixtures.task_fixture(%{source_id: ctx.source.id, job_id: job.id})
    assert {:error, :source_jobs_running} = LocalImport.preview(ctx.source.id, "")
    assert {:error, :source_jobs_running} = LocalImport.apply_preview(ctx.source.id, "", "anything")
    assert Repo.aggregate(MediaItem, :count) == 0
  end
end
