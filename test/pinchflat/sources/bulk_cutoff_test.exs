defmodule Pinchflat.Sources.BulkCutoffTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Sources.BulkCutoff

  test "normal retention honors the confirmed date, protects pinned media and includes the cutoff day" do
    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    source = source_fixture()
    old = media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-01 23:59:59Z]})

    protected =
      media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-01 12:00:00Z], prevent_culling: true})

    boundary = media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-02 00:00:00Z]})
    ids = ["#{source.id}"]
    {:ok, preview} = BulkCutoff.preview(ids, "2026-01-02")
    assert {:ok, [_]} = BulkCutoff.apply_preview(ids, "2026-01-02", preview.fingerprint)

    assert File.exists?(old.media_filepath)
    assert :ok = perform_job(Pinchflat.Downloading.MediaRetentionWorker, %{})
    refute File.exists?(old.media_filepath)
    assert File.exists?(protected.media_filepath)
    assert File.exists?(boundary.media_filepath)
  end

  test "preview counts removal candidates without changing dates, jobs or files" do
    source = source_fixture()
    old = media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-01 23:59:59Z]})

    protected =
      media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-01 12:00:00Z], prevent_culling: true})

    media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-02 00:00:00Z]})
    other = source_fixture()
    media_item_with_attachments(%{source_id: other.id, uploaded_at: ~U[2026-01-01 00:00:00Z]})
    bytes = File.read!(old.media_filepath)
    jobs = Repo.aggregate(Oban.Job, :count)

    assert {:ok, preview} = BulkCutoff.preview(["#{source.id}"], "2026-01-02")
    assert preview.downloaded_before == 2
    assert preview.removable == 1
    assert is_nil(Repo.reload!(source).download_cutoff_date)
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert File.read!(old.media_filepath) == bytes
    assert File.exists?(protected.media_filepath)
  end

  test "confirmation changes only selected dates and leaves retention to the normal worker" do
    source = source_fixture(download_cutoff_date: ~D[2025-01-01])
    other = source_fixture()
    old = media_item_with_attachments(%{source_id: source.id, uploaded_at: ~U[2026-01-01 00:00:00Z]})
    original = File.read!(old.media_filepath)
    jobs = Repo.aggregate(Oban.Job, :count)
    ids = ["#{source.id}"]
    {:ok, preview} = BulkCutoff.preview(ids, "2026-01-02")

    assert {:ok, [_]} = BulkCutoff.apply_preview(ids, "2026-01-02", preview.fingerprint)
    updated = Repo.reload!(source)
    assert updated.download_cutoff_date == ~D[2026-01-02]
    assert updated.enabled == source.enabled
    assert updated.download_media == source.download_media
    assert updated.index_cutoff_date == source.index_cutoff_date
    assert is_nil(Repo.reload!(other).download_cutoff_date)
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert File.read!(old.media_filepath) == original
  end

  test "clearing a cutoff has no removal candidates and preserves a paused source" do
    source = source_fixture(download_cutoff_date: ~D[2026-01-01], download_media: false)
    ids = ["#{source.id}"]
    assert {:ok, preview} = BulkCutoff.preview(ids, "")
    assert preview.removable == 0
    assert {:ok, [_]} = BulkCutoff.apply_preview(ids, "", preview.fingerprint)
    assert is_nil(Repo.reload!(source).download_cutoff_date)
    refute Repo.reload!(source).download_media
  end

  test "invalid dates, invalid selections and indexing conflicts change nothing" do
    valid = source_fixture()
    conflict = source_fixture(index_cutoff_date: ~D[2026-02-01], download_cutoff_date: ~D[2026-03-01])
    assert {:error, _} = BulkCutoff.preview(["#{valid.id}", "#{conflict.id}"], "2026-01-01")

    for value <- [nil, "bad", "2026-02-30", %{}] do
      assert {:error, _} = BulkCutoff.preview(["#{valid.id}"], value)
    end

    assert {:error, _} = BulkCutoff.preview([], "2026-01-01")
    assert {:error, _} = BulkCutoff.preview(["#{valid.id}", "999999999"], "2026-01-01")
    assert is_nil(Repo.reload!(valid).download_cutoff_date)
  end

  test "a changed source invalidates the preview for the entire selection" do
    first = source_fixture()
    second = source_fixture()
    ids = ["#{first.id}", "#{second.id}"]
    {:ok, preview} = BulkCutoff.preview(ids, "2026-01-02")
    second |> Ecto.Changeset.change(download_cutoff_date: ~D[2025-01-01]) |> Repo.update!()

    assert {:error, :stale_preview} = BulkCutoff.apply_preview(ids, "2026-01-02", preview.fingerprint)
    assert is_nil(Repo.reload!(first).download_cutoff_date)
    assert Repo.reload!(second).download_cutoff_date == ~D[2025-01-01]
  end
end
