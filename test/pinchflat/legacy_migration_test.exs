defmodule Pinchflat.LegacyMigrationTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.LegacyMigration
  alias Pinchflat.LegacyMigration.Record
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.Repo
  alias Pinchflat.Sources

  @test_state_file Path.join(
                     System.tmp_dir!(),
                     "test_legacy_migration_state_#{System.unique_integer([:positive])}.json"
                   )

  setup do
    Application.put_env(:pinchflat, :legacy_migration_state_path, @test_state_file)
    File.rm(@test_state_file)

    on_exit(fn ->
      Application.delete_env(:pinchflat, :legacy_migration_state_path)
      File.rm(@test_state_file)
    end)

    :ok
  end

  describe "legacy migration state file management" do
    test "defaults to fresh install / completed when no state file exists" do
      refute LegacyMigration.legacy_provenance_detected?()
      refute LegacyMigration.legacy_migration_pending?()
      assert %{status: "completed"} = LegacyMigration.get_state()
    end

    test "records and detects positive legacy provenance" do
      state = %{
        provenance: "legacy_pinchflat",
        status: "pending_review",
        detected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        original_max_version: 20_250_317_213_740,
        source_count: 5
      }

      File.write!(@test_state_file, Jason.encode!(state))
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      assert LegacyMigration.legacy_provenance_detected?()
      assert LegacyMigration.legacy_migration_pending?()

      # complete_review! transitions status to completed
      LegacyMigration.complete_review!()
      LegacyMigration.release_mutating_queues!()
      assert LegacyMigration.legacy_provenance_detected?()
      refute LegacyMigration.legacy_migration_pending?()
      assert LegacyMigration.get_state().status == "completed"
    end
  end

  describe "pre_migration_check/1" do
    test "detects existing NGX when migrations are already up to date" do
      # In the test database, all migrations have run (max_version > 20250317213740)
      state = LegacyMigration.pre_migration_check(Repo)

      assert state.provenance in ["existing_ngx", "existing_or_fresh"]
      assert state.status == "completed"
      refute LegacyMigration.legacy_migration_pending?()
    end
  end

  describe "source name preservation and locking" do
    test "locking protects custom_name from automated metadata refresh while allowing description refresh" do
      source =
        source_fixture(%{
          custom_name: "Original Custom Name",
          custom_name_locked: true,
          description: "Old Description",
          description_locked: false
        })

      # Automated metadata refresh attempts to update both
      {:ok, updated} =
        Sources.update_source(
          source,
          %{
            custom_name: "Extracted Channel Name",
            description: "New Extracted Description"
          },
          automated_metadata_refresh: true
        )

      # custom_name remains locked, description updates
      assert updated.custom_name == "Original Custom Name"
      assert updated.description == "New Extracted Description"
    end

    test "unlocked source allows automated custom_name refresh (standard NGX behavior)" do
      source =
        source_fixture(%{
          custom_name: "Default Channel Name",
          custom_name_locked: false,
          description: "Old Description"
        })

      {:ok, updated} =
        Sources.update_source(
          source,
          %{
            custom_name: "Extracted Channel Name",
            description: "New Extracted Description"
          },
          automated_metadata_refresh: true
        )

      assert updated.custom_name == "Extracted Channel Name"
      assert updated.description == "New Extracted Description"
    end
  end

  describe "mutating queue management" do
    test "hold_mutating_queues! and release_mutating_queues! succeed" do
      assert :ok = LegacyMigration.hold_mutating_queues!()
      assert :ok = LegacyMigration.release_mutating_queues!()
      assert :media_fetching in LegacyMigration.mutating_queues()
      assert :remote_metadata in LegacyMigration.mutating_queues()
      assert :fast_indexing in LegacyMigration.mutating_queues()
      assert :media_collection_indexing in LegacyMigration.mutating_queues()
      assert :maintenance in LegacyMigration.mutating_queues()
    end
  end

  describe "verify_library/0" do
    test "verifies accessible files and separates recorded from verified totals" do
      test_dir = Path.join(System.tmp_dir!(), "lib_verify_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)
      test_file = Path.join(test_dir, "sample.mp4")
      File.write!(test_file, "sample binary content for testing verification")
      test_size = byte_size("sample binary content for testing verification")

      _accessible_item =
        media_item_fixture(%{
          media_filepath: test_file,
          media_size_bytes: test_size
        })

      _missing_item =
        media_item_fixture(%{
          media_filepath: "/nonexistent/path/missing_file.mp4",
          media_size_bytes: 50_000,
          title: "Missing Video Title"
        })

      summary = LegacyMigration.verify_library()

      assert summary.db_downloaded_count >= 2
      assert summary.db_downloaded_bytes >= test_size + 50_000
      assert summary.verified_count >= 1
      assert summary.verified_bytes >= test_size
      assert summary.missing_count >= 1

      missing_entry = Enum.find(summary.missing_items, &(&1.title == "Missing Video Title"))
      assert missing_entry != nil
      assert missing_entry.filepath == "/nonexistent/path/missing_file.mp4"
      assert missing_entry.error == "enoent"

      # Also test get_or_run_verification returns cached scan
      cached = LegacyMigration.get_or_run_verification()
      assert cached.missing_count == summary.missing_count

      File.rm_rf!(test_dir)
    end
  end

  describe "channel artwork detection and scheduling" do
    test "channel_artwork_missing?/1 detects missing and present artwork accurately" do
      # Non-channel sources return false
      playlist = source_fixture(%{collection_type: :playlist})
      video = source_fixture(%{collection_type: :video})
      refute LegacyMigration.channel_artwork_missing?(playlist)
      refute LegacyMigration.channel_artwork_missing?(video)

      # Channel with neither poster nor banner returns true
      channel = source_fixture(%{collection_type: :channel})
      assert LegacyMigration.channel_artwork_missing?(channel)

      # Channel with existing custom poster and existing fanart returns false
      folder = MetadataFileHelpers.metadata_directory_for(channel)
      File.mkdir_p!(folder)
      custom_poster_file = Path.join(folder, "custom-poster-00000000-0000-0000-0000-000000000001.jpg")
      fanart_file = Path.join(folder, "fanart.jpg")
      File.write!(custom_poster_file, "custom poster")
      File.write!(fanart_file, "channel fanart")

      channel =
        channel
        |> Ecto.Changeset.change(custom_poster_filename: Path.basename(custom_poster_file))
        |> Repo.update!()
        |> Repo.preload(:metadata)

      {:ok, channel_with_art} =
        Sources.update_source(channel, %{
          metadata: %{
            metadata_filepath: Path.join(folder, "source.json.gz"),
            fanart_filepath: fanart_file
          }
        })

      refute LegacyMigration.channel_artwork_missing?(channel_with_art)

      # Channel with missing referenced file returns true
      missing_poster_file = Path.join(folder, "deleted-poster.jpg")

      channel_no_custom =
        channel_with_art
        |> Ecto.Changeset.change(custom_poster_filename: nil)
        |> Repo.update!()
        |> Repo.preload(:metadata)

      {:ok, channel_broken_ref} =
        Sources.update_source(channel_no_custom, %{
          metadata: %{
            metadata_filepath: Path.join(folder, "source.json.gz"),
            poster_filepath: missing_poster_file,
            fanart_filepath: fanart_file
          }
        })

      assert LegacyMigration.channel_artwork_missing?(channel_broken_ref)

      # Channel with existing UI poster returns false
      real_poster_file = Path.join(folder, "poster.jpg")
      File.write!(real_poster_file, "real poster")
      channel_broken_ref = Repo.preload(channel_broken_ref, :metadata)

      {:ok, channel_ui_art} =
        Sources.update_source(channel_broken_ref, %{
          metadata: %{
            metadata_filepath: Path.join(folder, "source.json.gz"),
            poster_filepath: real_poster_file
          }
        })

      refute LegacyMigration.channel_artwork_missing?(channel_ui_art)

      File.rm(custom_poster_file)
      File.rm(fanart_file)
      File.rm(real_poster_file)
    end

    test "complete_review! and enqueue_missing_channel_artwork_tasks record and enqueue repairs" do
      channel = source_fixture(%{collection_type: :channel})
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      assert LegacyMigration.channel_artwork_missing?(channel)

      assert :ok = LegacyMigration.complete_review!()

      status = LegacyMigration.artwork_repair_status()
      assert status["status"] in ["completed", "pending"]
      assert status["total_missing"] >= 1
      assert channel.id in status["missing_source_ids"]
      assert channel.id in status["enqueued_source_ids"]

      # Verification of job enqueue with artwork_repair mode
      assert_enqueued(
        worker: SourceMetadataStorageWorker,
        args: %{"id" => channel.id, "mode" => "artwork_repair"}
      )

      # Idempotent re-run does not crash or double-enqueue
      assert :ok = LegacyMigration.resume_artwork_repairs!()
    end

    test "resume_artwork_repairs! recovers unscheduled sources after restart" do
      channel = source_fixture(%{collection_type: :channel})
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      # Simulate an interrupted review state where intent was recorded but job was not enqueued
      record = Repo.one!(Record)

      record
      |> Ecto.Changeset.change(
        status: "completed",
        artwork_repairs: %{
          "status" => "pending",
          "missing_source_ids" => [channel.id],
          "enqueued_source_ids" => [],
          "failed_source_ids" => [],
          "total_missing" => 1,
          "enqueued_count" => 0,
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )
      |> Repo.update!()

      assert :ok = LegacyMigration.resume_artwork_repairs!()

      updated_status = LegacyMigration.artwork_repair_status()
      assert updated_status["status"] == "completed"
      assert channel.id in updated_status["enqueued_source_ids"]
      assert updated_status["enqueued_count"] == 1

      assert_enqueued(
        worker: SourceMetadataStorageWorker,
        args: %{"id" => channel.id, "mode" => "artwork_repair"}
      )
    end

    test "retry_artwork_repairs! resets and re-enqueues missing channels" do
      channel = source_fixture(%{collection_type: :channel})
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      {:ok, status} = LegacyMigration.retry_artwork_repairs!()
      assert status["status"] in ["completed", "pending"]
      assert channel.id in status["missing_source_ids"]
      assert channel.id in status["enqueued_source_ids"]
    end
  end
end
