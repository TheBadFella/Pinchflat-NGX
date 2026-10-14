defmodule Pinchflat.Diagnostics.MigrationCheckTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Diagnostics.MigrationCheck
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.CustomPoster

  describe "scan/0" do
    test "executes read-only scan without modifying database or queues" do
      source = source_fixture(%{custom_name: "Test Source", custom_name_locked: true})
      pre_source = Repo.reload!(source)

      result = MigrationCheck.scan()

      assert is_map(result)
      assert is_map(result.summary)
      assert is_list(result.findings)
      assert result.summary.total_sources >= 1

      # Verify source record was not mutated
      post_source = Repo.reload!(source)
      assert pre_source.custom_name == post_source.custom_name
      assert pre_source.custom_name_locked == post_source.custom_name_locked
    end
  end

  describe "scan_source_naming/0" do
    test "flags unlocked sources as ambiguous exposure and skips locked sources" do
      unlocked_source =
        source_fixture(%{custom_name: "Unlocked Channel", custom_name_locked: false})

      locked_source =
        source_fixture(%{custom_name: "Locked Channel", custom_name_locked: true})

      findings = MigrationCheck.scan_source_naming()

      assert Enum.any?(findings, fn f ->
               f.category == :source_naming and
                 f.classification == :ambiguous and
                 f.entity_id == unlocked_source.id
             end)

      refute Enum.any?(findings, fn f ->
               f.entity_id == locked_source.id
             end)
    end
  end

  describe "scan_media_files/0" do
    test "detects missing downloaded files as proved without deleting or clearing references" do
      test_dir = Path.join(System.tmp_dir!(), "check_media_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)
      accessible_path = Path.join(test_dir, "accessible.mp4")
      File.write!(accessible_path, "sample content")

      accessible_item =
        media_item_fixture(%{
          media_filepath: accessible_path,
          media_size_bytes: 14
        })

      missing_item =
        media_item_fixture(%{
          media_filepath: "/downloads/missing/video_not_on_disk.mp4",
          media_size_bytes: 50_000,
          title: "Missing Video Title"
        })

      findings = MigrationCheck.scan_media_files()

      missing_finding = Enum.find(findings, &(&1.entity_id == missing_item.id))
      assert missing_finding != nil
      assert missing_finding.category == :media_files
      assert missing_finding.classification == :proved
      assert missing_finding.details.reason == :enoent

      # Accessible item is not flagged
      refute Enum.any?(findings, &(&1.entity_id == accessible_item.id))

      # Verify database reference is strictly preserved (never cleared to nil or deleted)
      reloaded_missing = Repo.reload!(missing_item)
      assert reloaded_missing.media_filepath == "/downloads/missing/video_not_on_disk.mp4"

      File.rm_rf!(test_dir)
    end

    test "detects downloaded media items whose media_filepath was cleared to nil" do
      cleared_item =
        media_item_fixture(%{
          media_filepath: nil,
          media_downloaded_at: DateTime.utc_now(),
          title: "Historical Sync Cleared Video"
        })

      findings = MigrationCheck.scan_media_files()

      cleared_finding = Enum.find(findings, &(&1.entity_id == cleared_item.id))
      assert cleared_finding != nil
      assert cleared_finding.category == :media_files
      assert cleared_finding.classification == :proved
      assert cleared_finding.details.reason == :cleared_filepath
    end
  end

  describe "scan_artwork/0" do
    test "detects missing channel poster artwork and missing custom posters" do
      channel_missing_art =
        source_fixture(%{collection_type: :channel, custom_name: "No Art Channel"})

      channel_with_custom =
        source_fixture(%{collection_type: :channel, custom_name: "Custom Art Channel"})

      custom_filename = "custom-poster-00000000-0000-0000-0000-000000000002.jpg"

      channel_with_custom =
        Repo.update!(Ecto.Changeset.change(channel_with_custom, custom_poster_filename: custom_filename))

      custom_path = CustomPoster.filepath(channel_with_custom)
      # Ensure file does NOT exist on disk
      File.rm(custom_path)

      findings = MigrationCheck.scan_artwork()

      assert Enum.any?(findings, fn f ->
               f.category == :artwork and f.entity_id == channel_missing_art.id
             end)

      assert Enum.any?(findings, fn f ->
               f.category == :artwork and f.entity_id == channel_with_custom.id and
                 f.details[:filename] == custom_filename
             end)
    end
  end

  describe "scan_unavailable_metadata/0" do
    test "detects empty fallback JSON payload damage" do
      source = source_fixture(%{custom_name: "Empty Metadata Channel"})
      empty_meta_path = MetadataFileHelpers.compress_and_store_metadata_for(source, %{})

      source =
        source
        |> Repo.preload(:metadata)
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_assoc(:metadata, %{metadata_filepath: empty_meta_path})
        |> Repo.update!()

      findings = MigrationCheck.scan_unavailable_metadata()

      assert Enum.any?(findings, fn f ->
               f.category == :unavailable_metadata and
                 f.classification == :proved and
                 f.entity_id == source.id and
                 f.details[:reason] == :empty_fallback_json
             end)

      File.rm(empty_meta_path)
    end
  end

  describe "scan_notifications/0 and redact_url/1" do
    test "redacts secret token in Apprise server settings per R147-5" do
      Settings.set(apprise_server: "json://example.invalid/path?token=review147-fake-secret")
      findings = MigrationCheck.scan_notifications()

      refute inspect(findings) =~ "review147-fake-secret"
      assert hd(findings).details.apprise_server =~ "token=[REDACTED]"
    end

    test "redacts passwords in basic auth URLs and webhook paths" do
      assert MigrationCheck.redact_url("https://user:mypassword@example.com/notify") ==
               "https://user:[REDACTED]@example.com/notify"

      assert MigrationCheck.redact_url("discord://webhook_id/my_super_secret_webhook_token") ==
               "discord://webhook_id/[REDACTED]"

      assert MigrationCheck.redact_url("telegram://123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11/12345") ==
               "telegram://[REDACTED]/12345"
    end
  end
end
