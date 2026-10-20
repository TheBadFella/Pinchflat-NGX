defmodule Pinchflat.YoutubeBrowser.IntakeTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Tasks.Task
  alias Pinchflat.YoutubeBrowser.Intake

  describe "download_video/3 with existing library items" do
    test "B11: queues only the exact single existing item without force" do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id})

      # Create 2 items in the source
      item_1 =
        media_item_fixture(%{
          media_id: "vid_target",
          source_id: source.id,
          media_filepath: nil
        })

      item_2 =
        media_item_fixture(%{
          media_id: "vid_other",
          source_id: source.id,
          media_filepath: nil
        })

      assert {:ok, :queued} = Intake.download_video("vid_target", profile.id)

      # Verify item_1 has an active task
      tasks_1 = Repo.all(from t in Task, where: t.media_item_id == ^item_1.id)
      assert length(tasks_1) == 1

      # Verify item_2 was NOT queued
      tasks_2 = Repo.all(from t in Task, where: t.media_item_id == ^item_2.id)
      assert tasks_2 == []
    end

    test "B11: refuses download if source is intentionally disabled/paused" do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id, enabled: false})

      _item =
        media_item_fixture(%{
          media_id: "vid_paused_source",
          source_id: source.id,
          media_filepath: nil
        })

      assert {:error, :source_disabled} = Intake.download_video("vid_paused_source", profile.id)
    end

    test "B11: refuses download if media item has prevent_download flag" do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id})

      _item =
        media_item_fixture(%{
          media_id: "vid_prevented",
          source_id: source.id,
          media_filepath: nil,
          prevent_download: true
        })

      assert {:error, :download_prevented} = Intake.download_video("vid_prevented", profile.id)
    end

    test "B11: refuses download if file is already present on disk" do
      tmp_dir = Application.fetch_env!(:pinchflat, :media_directory)
      file_path = Path.join(tmp_dir, "vid_present_#{System.unique_integer([:positive])}.mp4")
      File.write!(file_path, "present bytes")

      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id})

      _item =
        media_item_fixture(%{
          media_id: "vid_already_here",
          source_id: source.id,
          media_filepath: file_path
        })

      assert {:error, :already_present} = Intake.download_video("vid_already_here", profile.id)

      File.rm(file_path)
    end

    test "B11: refuses download if file path exists in DB but is missing on disk" do
      missing_path =
        Path.join(
          Application.fetch_env!(:pinchflat, :media_directory),
          "missing_#{System.unique_integer([:positive])}.mp4"
        )

      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id})

      _item =
        media_item_fixture(%{
          media_id: "vid_missing_on_disk",
          source_id: source.id,
          media_filepath: missing_path
        })

      assert {:error, :missing_file} = Intake.download_video("vid_missing_on_disk", profile.id)
    end

    test "B11: returns :already_queued if an active job already exists" do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id})

      item =
        media_item_fixture(%{
          media_id: "vid_active_job",
          source_id: source.id,
          media_filepath: nil
        })

      {:ok, _task} = MediaDownloadWorker.kickoff_with_task(item)

      assert {:error, :already_queued} = Intake.download_video("vid_active_job", profile.id)
    end

    test "B11: returns :ambiguous_copies if multiple copies exist under the same profile" do
      profile = media_profile_fixture()
      source_1 = source_fixture(%{media_profile_id: profile.id, custom_name: "Source 1"})
      source_2 = source_fixture(%{media_profile_id: profile.id, custom_name: "Source 2"})

      _item_1 = media_item_fixture(%{media_id: "vid_ambig", source_id: source_1.id, media_filepath: nil})
      _item_2 = media_item_fixture(%{media_id: "vid_ambig", source_id: source_2.id, media_filepath: nil})

      assert {:error, :ambiguous_copies} = Intake.download_video("vid_ambig", profile.id)
    end
  end

  describe "download_video/3 with new videos" do
    test "B12: creates only a single-video source and schedules indexing task" do
      profile = media_profile_fixture()

      source_count_before = Repo.aggregate(Source, :count, :id)

      assert {:ok, :indexing} =
               Intake.download_video("vid_brand_new", profile.id, video_title: "My New Video")

      assert Repo.aggregate(Source, :count, :id) == source_count_before + 1

      created_source =
        Repo.get_by(Source, collection_id: "vid_brand_new", media_profile_id: profile.id)

      assert created_source != nil
      assert created_source.collection_type == :video
      assert created_source.index_frequency_minutes == 0
      assert created_source.fast_index == false
      assert created_source.custom_name == "My New Video"
      assert created_source.original_url == "https://www.youtube.com/watch?v=vid_brand_new"

      # Check that an indexing task was created for this source
      tasks = Repo.all(from t in Task, where: t.source_id == ^created_source.id)
      assert length(tasks) == 1
    end

    test "B13: repeat calls converge on the single created source without duplicate errors" do
      profile = media_profile_fixture()

      # First call creates the source
      assert {:ok, :indexing} = Intake.download_video("vid_repeat_test", profile.id)

      # Second call detects existing source and active job -> :already_queued
      assert {:error, :already_queued} = Intake.download_video("vid_repeat_test", profile.id)

      # Total sources created for this video is exactly 1
      sources =
        Repo.all(from s in Source, where: s.collection_id == "vid_repeat_test")

      assert length(sources) == 1
    end
  end

  describe "indexed intake titles" do
    test "only the matching generated video name is resolved, including retries" do
      source =
        source_fixture(
          collection_type: :video,
          collection_id: "title_test",
          custom_name: "YouTube Video title_test",
          collection_name: "YouTube Video title_test"
        )

      updated = Pinchflat.Sources.resolve_intake_video_title(source, "title_test", "Resolved title")
      assert updated.custom_name == "Resolved title"
      assert updated.collection_name == "Resolved title"

      assert Pinchflat.Sources.resolve_intake_video_title(source, "title_test", "Later title").custom_name ==
               "Resolved title"
    end

    test "an edit committed after indexing starts survives the stale source snapshot" do
      source =
        source_fixture(
          collection_type: :video,
          collection_id: "title_edit",
          custom_name: "YouTube Video title_edit",
          collection_name: "YouTube Video title_edit"
        )

      source |> Ecto.Changeset.change(custom_name: "User's name") |> Repo.update!()

      assert Pinchflat.Sources.resolve_intake_video_title(source, "title_edit", "Fetched title").custom_name ==
               "User's name"
    end

    test "a lock committed during indexing survives the stale source snapshot" do
      source =
        source_fixture(
          collection_type: :video,
          collection_id: "title_lock",
          custom_name: "YouTube Video title_lock",
          collection_name: "YouTube Video title_lock"
        )

      source |> Ecto.Changeset.change(custom_name_locked: true) |> Repo.update!()

      assert Pinchflat.Sources.resolve_intake_video_title(source, "title_lock", "Fetched title").custom_name ==
               source.custom_name
    end

    test "a source retargeted during indexing keeps its new identity" do
      source =
        source_fixture(
          collection_type: :video,
          collection_id: "old_video",
          custom_name: "YouTube Video old_video",
          collection_name: "YouTube Video old_video"
        )

      source |> Ecto.Changeset.change(collection_id: "new_video") |> Repo.update!()

      assert Pinchflat.Sources.resolve_intake_video_title(source, "old_video", "Old title").custom_name ==
               source.custom_name
    end

    test "missing titles and mismatched video IDs leave the placeholder alone" do
      source =
        source_fixture(
          collection_type: :video,
          collection_id: "title_missing",
          custom_name: "YouTube Video title_missing",
          collection_name: "YouTube Video title_missing"
        )

      for title <- [nil, "", "   "] do
        assert Pinchflat.Sources.resolve_intake_video_title(source, "title_missing", title).custom_name ==
                 source.custom_name
      end

      assert Pinchflat.Sources.resolve_intake_video_title(source, "another_video", "Fetched title").custom_name ==
               source.custom_name
    end
  end

  describe "safety boundaries and invalid inputs" do
    test "B14: rejects invalid or non-existent profile ID" do
      assert {:error, :invalid_profile} = Intake.download_video("vid_123", 999_999)
      assert {:error, :invalid_profile} = Intake.download_video("vid_123", nil)
    end

    test "B14: rejects malformed video ID" do
      profile = media_profile_fixture()
      assert {:error, :invalid_video_id} = Intake.download_video("", profile.id)
      assert {:error, :invalid_video_id} = Intake.download_video("bad/id/injection", profile.id)
    end

    test "B09: refuses download when postgres migration hold is active" do
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
      on_exit(fn -> Application.delete_env(:pinchflat, :postgres_migration_boot_held) end)

      profile = media_profile_fixture()
      assert {:error, :migration_hold_active} = Intake.download_video("vid_123", profile.id)
    end

    test "B09: refuses download when legacy migration hold is active" do
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()

      profile = media_profile_fixture()
      assert {:error, :migration_hold_active} = Intake.download_video("vid_123", profile.id)
    end
  end
end
