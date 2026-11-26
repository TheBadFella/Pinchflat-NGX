defmodule PinchflatWeb.Helpers.MediaCleanupHelpersTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias PinchflatWeb.Helpers.MediaCleanupHelpers

  describe "cutoff_cleanup?/2" do
    test "returns true for an unprotected item published before a fixed cutoff" do
      source = source_fixture(download_cutoff_date: ~D[2026-10-25])
      item = %{uploaded_at: ~U[2026-10-24 12:00:00Z], prevent_culling: false}

      assert MediaCleanupHelpers.cutoff_cleanup?(item, source)
    end

    test "returns false on the fixed cutoff day" do
      source = source_fixture(download_cutoff_date: ~D[2026-10-25])
      item = %{uploaded_at: ~U[2026-10-25 12:00:00Z], prevent_culling: false}

      refute MediaCleanupHelpers.cutoff_cleanup?(item, source)
    end

    test "resolves a rolling window relative to today" do
      source = source_fixture(download_cutoff_days: 30)
      today = Date.utc_today()

      outside = %{
        uploaded_at: DateTime.new!(Date.add(today, -31), ~T[12:00:00], "Etc/UTC"),
        prevent_culling: false
      }

      boundary = %{
        uploaded_at: DateTime.new!(Date.add(today, -30), ~T[12:00:00], "Etc/UTC"),
        prevent_culling: false
      }

      assert MediaCleanupHelpers.cutoff_cleanup?(outside, source)
      refute MediaCleanupHelpers.cutoff_cleanup?(boundary, source)
    end

    test "returns false when there is no cutoff or the item is protected" do
      no_cutoff = source_fixture(download_cutoff_date: nil, download_cutoff_days: nil)
      with_cutoff = source_fixture(download_cutoff_days: 1)
      item = %{uploaded_at: ~U[2026-10-24 12:00:00Z], prevent_culling: true}

      refute MediaCleanupHelpers.cutoff_cleanup?(%{uploaded_at: ~U[2026-10-24 12:00:00Z]}, no_cutoff)
      refute MediaCleanupHelpers.cutoff_cleanup?(item, with_cutoff)
    end
  end

  describe "cutoff_cleanup_warning/2" do
    test "names a fixed cutoff date" do
      source = source_fixture(download_cutoff_date: ~D[2026-10-25])
      item = %{uploaded_at: ~U[2026-10-20 12:00:00Z]}

      assert MediaCleanupHelpers.cutoff_cleanup_warning(item, source) =~
               "This video was published on 2026-10-20, before this source's download cutoff date of 2026-10-25."
    end

    test "names a rolling cutoff and its window" do
      source = source_fixture(download_cutoff_days: 30)
      today = Date.utc_today()
      cutoff = Date.add(today, -30) |> Date.to_iso8601()
      item = %{uploaded_at: DateTime.new!(Date.add(today, -40), ~T[12:00:00], "Etc/UTC")}

      assert MediaCleanupHelpers.cutoff_cleanup_warning(item, source) =~
               "before this source's rolling download cutoff of #{cutoff} " <>
                 "(last 30 days on #{Date.to_iso8601(today)})"
    end
  end
end
