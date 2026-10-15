defmodule Pinchflat.SourceDiagnosticsTest do
  use Pinchflat.DataCase, async: false

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources

  defp undownloaded_item(attrs) do
    media_item_fixture(Keyword.put(attrs, :media_filepath, nil))
  end

  defp conditions(source, counts \\ nil) do
    opts = [queue_paused?: false, storage_directory_writable?: true, indexing_failed?: false]
    opts = if counts, do: Keyword.put(opts, :tab_counts, counts), else: opts
    Sources.blocking_conditions(source, opts)
  end

  test "skipped items before the cutoff explain why nothing downloads" do
    source = source_fixture(download_cutoff_date: ~D[2025-11-22])
    undownloaded_item(source_id: source.id, uploaded_at: ~U[2025-11-21 23:59:59Z])

    assert [%{code: :cutoff_excludes_everything}] = conditions(source)
  end

  test "the cutoff day is inclusive through its last second" do
    source = source_fixture(download_cutoff_date: ~D[2025-11-22])

    for timestamp <- [~U[2025-11-22 00:00:00Z], ~U[2025-11-22 23:59:59Z]] do
      undownloaded_item(source_id: source.id, uploaded_at: timestamp)
    end

    assert Sources.tab_counts(source).pending == 2
    assert conditions(source) == []
  end

  test "mixed cutoff and other exclusions do not blame only the cutoff" do
    source = source_fixture(download_cutoff_date: ~D[2025-11-22], title_filter_regex: "^Keep")
    undownloaded_item(source_id: source.id, title: "Keep old video", uploaded_at: ~U[2025-11-21 00:00:00Z])
    undownloaded_item(source_id: source.id, title: "Exclude new video", uploaded_at: ~U[2025-11-23 00:00:00Z])

    assert [%{code: :all_filtered_out}] = conditions(source)
  end

  test "missing upload dates are rejected rather than saved as cutoff exclusions" do
    changeset = Pinchflat.Media.MediaItem.changeset(%Pinchflat.Media.MediaItem{}, %{uploaded_at: nil})
    assert "can't be blank" in errors_on(changeset).uploaded_at
  end

  test "downloaded and other-source records do not inflate cutoff exclusions" do
    source = source_fixture(download_cutoff_date: ~D[2025-11-22])
    undownloaded_item(source_id: source.id, uploaded_at: ~U[2025-11-21 00:00:00Z])

    media_item_fixture(
      source_id: source.id,
      uploaded_at: ~U[2025-11-21 00:00:00Z]
    )

    undownloaded_item(uploaded_at: ~U[2025-11-21 00:00:00Z])
    assert [%{code: :cutoff_excludes_everything}] = conditions(source, %{pending: 0, library: 0, skipped: 1})
    assert conditions(source) == []
  end

  test "nil cutoff, empty sources and disabled sources remain safe" do
    source = source_fixture(title_filter_regex: "^Keep")
    undownloaded_item(source_id: source.id, title: "Excluded", uploaded_at: ~U[2025-11-21 00:00:00Z])
    assert [%{code: :all_filtered_out}] = conditions(source)

    empty = source_fixture(download_cutoff_date: ~D[2025-11-22])
    assert [%{code: :never_indexed}] = conditions(empty)
    assert conditions(%{source | enabled: false, download_cutoff_date: ~D[2025-11-22]}) == []
  end
end
