defmodule Pinchflat.YoutubeBrowser.StatusTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Repo
  alias Pinchflat.YoutubeBrowser.Status

  defp count_repo_queries(fun) do
    ref = make_ref()
    parent = self()

    handler = fn _event, _measurements, metadata, _config ->
      # Ignore sandbox savepoints / begin / commit if checking raw queries or count all queries
      if Map.has_key?(metadata, :query) and not String.contains?(metadata.query, "SAVEPOINT") do
        send(parent, {ref, :query})
      end
    end

    handler_id = "test-query-counter-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler_id, [:pinchflat, :repo, :query], handler, nil)

    try do
      fun.()
      drain_query_messages(ref, 0)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_messages(ref, acc) do
    receive do
      {^ref, :query} -> drain_query_messages(ref, acc + 1)
    after
      20 -> acc
    end
  end

  describe "enrich_videos/2" do
    test "returns empty map for empty or blank IDs" do
      assert Status.enrich_videos([]) == %{}
      assert Status.enrich_videos(["", "   "]) == %{}
    end

    test "B08: correctly identifies :in_library when file exists on disk" do
      # Create temporary file
      tmp_dir = Application.fetch_env!(:pinchflat, :media_directory)
      file_path = Path.join(tmp_dir, "test_video_present_#{System.unique_integer([:positive])}.mp4")
      File.write!(file_path, "dummy video content")

      source = source_fixture()

      media_item =
        media_item_fixture(%{
          media_id: "vid_present_1",
          source_id: source.id,
          media_filepath: file_path
        })

      results = Status.enrich_videos(["vid_present_1"], selected_profile_id: source.media_profile_id)
      status = Map.get(results, "vid_present_1")

      assert status != nil
      assert status.state == :in_library
      assert status.badge_text == "In library"
      assert status.can_download? == false
      assert status.open_local_path == "/sources/#{source.id}/media/#{media_item.id}"

      File.rm(file_path)
    end

    test "B08: correctly identifies :missing_file when file is missing from disk" do
      tmp_dir = Application.fetch_env!(:pinchflat, :media_directory)
      missing_path = Path.join(tmp_dir, "video_missing_#{System.unique_integer([:positive])}.mp4")

      source = source_fixture()

      media_item =
        media_item_fixture(%{
          media_id: "vid_missing_1",
          source_id: source.id,
          media_filepath: missing_path
        })

      results = Status.enrich_videos(["vid_missing_1"], selected_profile_id: source.media_profile_id)
      status = Map.get(results, "vid_missing_1")

      assert status != nil
      assert status.state == :missing_file
      assert status.badge_text == "Missing file"
      assert status.can_download? == false
      assert status.open_local_path == "/sources/#{source.id}/media/#{media_item.id}"
    end

    test "B08: correctly identifies :prevented, :culled, and :unavailable states" do
      source = source_fixture()

      # Prevented
      _prevented_item =
        media_item_fixture(%{
          media_id: "vid_prev",
          source_id: source.id,
          media_filepath: nil,
          prevent_download: true,
          download_prevented_reason: :manual
        })

      # Culled
      _culled_item =
        media_item_fixture(%{
          media_id: "vid_cull",
          source_id: source.id,
          media_filepath: nil,
          culled_at: DateTime.utc_now()
        })

      # Unavailable
      _unavail_item =
        media_item_fixture(%{
          media_id: "vid_unavail",
          source_id: source.id,
          media_filepath: nil,
          unavailable_at: DateTime.utc_now(),
          unavailable_reason: "Private video"
        })

      results =
        Status.enrich_videos(["vid_prev", "vid_cull", "vid_unavail"], selected_profile_id: source.media_profile_id)

      prev_status = Map.get(results, "vid_prev")
      assert prev_status.state == :prevented
      assert prev_status.can_download? == false

      cull_status = Map.get(results, "vid_cull")
      assert cull_status.state == :culled
      assert cull_status.can_download? == false

      unavail_status = Map.get(results, "vid_unavail")
      assert unavail_status.state == :unavailable
      assert unavail_status.can_download? == false
    end

    test "B08: correctly identifies :indexed (in library DB, but no downloaded file yet)" do
      source = source_fixture()

      _indexed_item =
        media_item_fixture(%{
          media_id: "vid_indexed_1",
          source_id: source.id,
          media_filepath: nil
        })

      results = Status.enrich_videos(["vid_indexed_1"], selected_profile_id: source.media_profile_id)
      status = Map.get(results, "vid_indexed_1")

      assert status != nil
      assert status.state == :indexed
      assert status.badge_text == "Indexed"
      assert status.can_download? == true
    end

    test "B09: detects active Oban job states (:downloading, :queued, :retrying)" do
      source = source_fixture()

      # Item 1: executing
      item_exec = media_item_fixture(%{media_id: "vid_exec", source_id: source.id, media_filepath: nil})
      {:ok, task_exec} = MediaDownloadWorker.kickoff_with_task(item_exec)
      # Update job to executing
      Repo.get!(Oban.Job, task_exec.job_id)
      |> Ecto.Changeset.change(%{state: "executing"})
      |> Repo.update!()

      # Update task progress
      task_exec
      |> Ecto.Changeset.change(%{progress_percent: 45.0, progress_status: "downloading"})
      |> Repo.update!()

      # Item 2: available/queued
      item_avail = media_item_fixture(%{media_id: "vid_avail", source_id: source.id, media_filepath: nil})
      {:ok, _task_avail} = MediaDownloadWorker.kickoff_with_task(item_avail)

      # Item 3: retryable
      item_retry = media_item_fixture(%{media_id: "vid_retry", source_id: source.id, media_filepath: nil})
      {:ok, task_retry} = MediaDownloadWorker.kickoff_with_task(item_retry)

      Repo.get!(Oban.Job, task_retry.job_id)
      |> Ecto.Changeset.change(%{state: "retryable"})
      |> Repo.update!()

      results =
        Status.enrich_videos(["vid_exec", "vid_avail", "vid_retry"], selected_profile_id: source.media_profile_id)

      exec_status = Map.get(results, "vid_exec")
      assert exec_status.state == :downloading
      assert exec_status.badge_text == "Downloading (45%)"
      assert exec_status.can_download? == false

      avail_status = Map.get(results, "vid_avail")
      assert avail_status.state == :queued
      assert avail_status.badge_text == "Queued"
      assert avail_status.can_download? == false

      retry_status = Map.get(results, "vid_retry")
      assert retry_status.state == :retrying
      assert retry_status.badge_text == "Retrying"
      assert retry_status.can_download? == false
    end

    test "B07: handles multi-source and alternate-profile copies correctly" do
      profile_a = media_profile_fixture(%{name: "Profile A"})
      profile_b = media_profile_fixture(%{name: "Profile B"})

      source_a = source_fixture(%{media_profile_id: profile_a.id, custom_name: "Source A"})
      source_b = source_fixture(%{media_profile_id: profile_b.id, custom_name: "Source B"})

      # Video exists in Profile B, but user has Profile A selected
      _item_b =
        media_item_fixture(%{
          media_id: "vid_multi_profile",
          source_id: source_b.id,
          media_filepath: nil
        })

      results = Status.enrich_videos(["vid_multi_profile"], selected_profile_id: profile_a.id)
      status = Map.get(results, "vid_multi_profile")

      assert status != nil
      assert status.state == :not_in_library
      assert status.can_download? == true
      assert status.badge_text == "In other profile (Profile B)"
      assert length(status.copies) == 1

      # Now video exists in both Profile A and Profile B
      _item_a =
        media_item_fixture(%{
          media_id: "vid_multi_profile",
          source_id: source_a.id,
          media_filepath: nil
        })

      results_both = Status.enrich_videos(["vid_multi_profile"], selected_profile_id: profile_a.id)
      status_both = Map.get(results_both, "vid_multi_profile")

      assert status_both.state == :indexed
      assert status_both.can_download? == true
      assert length(status_both.copies) == 2
    end

    test "B07: detects ambiguous copies when multiple copies exist under the same profile" do
      profile = media_profile_fixture(%{name: "Single Profile"})
      source_1 = source_fixture(%{media_profile_id: profile.id, custom_name: "Playlist 1"})
      source_2 = source_fixture(%{media_profile_id: profile.id, custom_name: "Playlist 2"})

      _item_1 = media_item_fixture(%{media_id: "vid_dup", source_id: source_1.id, media_filepath: nil})
      _item_2 = media_item_fixture(%{media_id: "vid_dup", source_id: source_2.id, media_filepath: nil})

      results = Status.enrich_videos(["vid_dup"], selected_profile_id: profile.id)
      status = Map.get(results, "vid_dup")

      assert status.state == :ambiguous_copies
      assert status.can_download? == false
      assert status.badge_text == "Multiple copies (2)"
      assert length(status.copies) == 2
    end

    test "B10: query count is constant (bounded <= 4) across 1 vs 25 results" do
      source = source_fixture()

      # Create 25 media items
      video_ids =
        for i <- 1..25 do
          vid = "perf_vid_#{i}"
          media_item_fixture(%{media_id: vid, source_id: source.id, media_filepath: nil})
          vid
        end

      # Query count for 1 item
      q_count_1 =
        count_repo_queries(fn ->
          Status.enrich_videos([List.first(video_ids)], selected_profile_id: source.media_profile_id)
        end)

      # Query count for 25 items
      q_count_25 =
        count_repo_queries(fn ->
          Status.enrich_videos(video_ids, selected_profile_id: source.media_profile_id)
        end)

      # Both must be <= 4 and identical (no N+1 lookups!)
      assert q_count_1 <= 4
      assert q_count_25 <= 4
      assert q_count_1 == q_count_25
    end
  end

  describe "enrich_channels/2" do
    test "returns empty map for empty or blank IDs" do
      assert Status.enrich_channels([]) == %{}
      assert Status.enrich_channels(["", " "]) == %{}
    end

    test "correctly identifies :not_tracked for unknown channel" do
      results = Status.enrich_channels(["UC_unknown_123"])
      status = Map.get(results, "UC_unknown_123")

      assert status.state == :not_tracked
      assert status.can_subscribe? == true
      assert status.open_source_id == nil
    end

    test "correctly identifies :subscribed and :disabled channels in selected profile" do
      profile = media_profile_fixture()

      src_sub =
        source_fixture(%{
          collection_id: "UC_subscribed",
          collection_type: "channel",
          enabled: true,
          media_profile_id: profile.id
        })

      src_dis =
        source_fixture(%{
          collection_id: "UC_disabled",
          collection_type: "channel",
          enabled: false,
          media_profile_id: profile.id
        })

      results = Status.enrich_channels(["UC_subscribed", "UC_disabled"], selected_profile_id: profile.id)

      sub_status = Map.get(results, "UC_subscribed")
      assert sub_status.state == :subscribed
      assert sub_status.badge_text == "Subscribed"
      assert sub_status.can_subscribe? == false
      assert sub_status.open_source_id == src_sub.id

      dis_status = Map.get(results, "UC_disabled")
      assert dis_status.state == :disabled
      assert dis_status.badge_text == "Disabled/Paused"
      assert dis_status.can_subscribe? == false
      assert dis_status.open_source_id == src_dis.id
    end

    test "identifies :tracked_other_profile and allows subscription in selected profile" do
      profile_a = media_profile_fixture(%{name: "Profile A"})
      profile_b = media_profile_fixture(%{name: "Profile B"})

      _src_b =
        source_fixture(%{
          collection_id: "UC_other_prof",
          collection_type: "channel",
          enabled: true,
          media_profile_id: profile_b.id
        })

      results = Status.enrich_channels(["UC_other_prof"], selected_profile_id: profile_a.id)
      status = Map.get(results, "UC_other_prof")

      assert status.state == :tracked_other_profile
      assert status.badge_text == "Tracked in Profile B"
      assert status.can_subscribe? == true
    end

    test "B10: query count for channels is constant (bounded <= 2) across 1 vs 25 results" do
      profile = media_profile_fixture()

      channel_ids =
        for i <- 1..25 do
          cid = "UC_perf_ch_#{i}"
          source_fixture(%{collection_id: cid, collection_type: "channel", media_profile_id: profile.id})
          cid
        end

      q_count_1 =
        count_repo_queries(fn ->
          Status.enrich_channels([List.first(channel_ids)], selected_profile_id: profile.id)
        end)

      q_count_25 =
        count_repo_queries(fn ->
          Status.enrich_channels(channel_ids, selected_profile_id: profile.id)
        end)

      assert q_count_1 <= 2
      assert q_count_25 <= 2
      assert q_count_1 == q_count_25
    end
  end

  describe "check_file_state/1" do
    test "verifies regular file within configured media root" do
      root = Application.fetch_env!(:pinchflat, :media_directory)
      path = Path.join(root, "valid_media_#{System.unique_integer([:positive])}.mp4")
      File.write!(path, "valid bytes")
      on_exit(fn -> File.rm(path) end)

      assert Status.check_file_state(path) == :verified_present
    end

    test "refuses files outside configured media roots" do
      prior = Application.get_env(:pinchflat, :media_directory)
      Application.put_env(:pinchflat, :media_directory, "/custom-root-#{System.unique_integer([:positive])}")
      on_exit(fn -> Application.put_env(:pinchflat, :media_directory, prior) end)

      path = Path.join(System.tmp_dir!(), "unverified_#{System.unique_integer([:positive])}.mp4")
      File.write!(path, "bytes")
      on_exit(fn -> File.rm(path) end)

      assert Status.check_file_state(path) == :unverified
    end

    test "refuses directories and system files" do
      assert Status.check_file_state("/etc/passwd") != :verified_present
      assert Status.check_file_state(System.tmp_dir!()) == :unverified
      assert Status.check_file_state(nil) == :no_path
      assert Status.check_file_state("") == :no_path
    end

    test "detects missing file within configured root" do
      root = Application.fetch_env!(:pinchflat, :media_directory)
      path = Path.join(root, "non_existent_#{System.unique_integer([:positive])}.mp4")
      assert Status.check_file_state(path) == :missing
    end
  end
end
