defmodule Pinchflat.YoutubeBrowser.ScopedIntakeWorkflowTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.MediaFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Settings.MediaItemOptionHandoff
  alias Pinchflat.Settings.PendingMediaItemOptions
  alias Pinchflat.Settings.YtDlpConfigFile
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.YoutubeBrowser.Intake

  defmodule FailingFS do
    def mkdir_p(_path), do: {:error, :eacces}
    def write(path, contents, opts), do: File.write(path, contents, opts)
    def rename(source, destination), do: File.rename(source, destination)
    def rm(path), do: File.rm(path)
    def read(path), do: File.read(path)
    def lstat(path), do: File.lstat(path)
    def exists?(path), do: File.exists?(path)
  end

  setup do
    original_extras = Application.get_env(:pinchflat, :extras_directory)
    original_fs = Application.get_env(:pinchflat, :yt_dlp_config_file_fs)
    original_hold = Application.get_env(:pinchflat, :postgres_migration_boot_held)
    extras = Path.join(System.tmp_dir!(), "scoped-intake-#{System.unique_integer([:positive])}")
    File.mkdir_p!(extras)
    Application.put_env(:pinchflat, :extras_directory, extras)
    Application.delete_env(:pinchflat, :yt_dlp_config_file_fs)
    Application.delete_env(:pinchflat, :postgres_migration_boot_held)

    on_exit(fn ->
      restore_env(:extras_directory, original_extras)
      restore_env(:yt_dlp_config_file_fs, original_fs)
      restore_env(:postgres_migration_boot_held, original_hold)
      File.rm_rf!(extras)
    end)

    :ok
  end

  test "W01: source options are saved before scheduling and load on download" do
    profile = media_profile_fixture()
    channel_id = "UC_scoped_#{System.unique_integer([:positive])}"

    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _template, _addl ->
      {:ok, source_details_return_fixture(%{channel_id: channel_id, playlist_id: channel_id})}
    end)

    assert {:ok, source} =
             Sources.create_source(
               %{
                 media_profile_id: profile.id,
                 source_type: :channel,
                 original_url: "https://www.youtube.com/channel/#{channel_id}"
               },
               yt_dlp_options: {:present, "--source-option\n"}
             )

    assert {:ok, source_path} = YtDlpConfigFile.scope_path(:source, source.id)
    assert File.read!(source_path) == "--source-option\n"
    assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})

    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

    stub_download_success(fn opts ->
      assert source_path in config_locations(opts)
    end)

    assert :ok = perform_job(MediaDownloadWorker, %{id: item.id})
  end

  test "W02: paste intake persists item options before the first download is queued" do
    profile = media_profile_fixture()
    video_id = "dQw4w9WgXcQ"

    assert {:ok, :indexing} =
             Intake.download_video(video_id, profile.id, %{"yt_dlp_options" => "--item-option\n"})

    source = Repo.get_by!(Source, collection_id: video_id, media_profile_id: profile.id)
    assert {:ok, %{contents: "--item-option\n"}} = PendingMediaItemOptions.fetch(source, video_id)

    stub_video_index(video_id, source)
    assert [_item] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

    item = Repo.get_by!(MediaItem, source_id: source.id, media_id: video_id)
    assert {:ok, %{contents: "--item-option\n", present?: true}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert {:ok, nil} = PendingMediaItemOptions.fetch(source, video_id)
    assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})
  end

  test "W05: profile options created with the profile load on downloads" do
    name = "Scoped profile #{System.unique_integer([:positive])}"

    assert {:ok, profile} =
             Profiles.create_media_profile(
               %{name: name, output_path_template: "{{ title }}.%(ext)s"},
               yt_dlp_options: {:present, "--profile-option\n"}
             )

    assert {:ok, profile_path} = YtDlpConfigFile.scope_path(:profile, profile.id)
    assert File.read!(profile_path) == "--profile-option\n"

    source = source_fixture(%{media_profile_id: profile.id})
    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

    stub_download_success(fn opts ->
      assert profile_path in config_locations(opts)
    end)

    assert :ok = perform_job(MediaDownloadWorker, %{id: item.id})
  end

  test "W06: existing item editor writes item options before the next download" do
    source = source_fixture()
    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

    assert {:ok, _item} =
             Media.update_media_item_with_yt_dlp_options(
               item,
               %{prevent_download: false},
               yt_dlp_options: {:present, "--item-editor\n"},
               yt_dlp_options_version: :missing
             )

    assert {:ok, item_path} = YtDlpConfigFile.scope_path(:media_item, item.id)
    assert File.read!(item_path) == "--item-editor\n"

    stub_download_success(fn opts ->
      assert item_path in config_locations(opts)
    end)

    assert :ok = perform_job(MediaDownloadWorker, %{id: item.id})
  end

  test "F10: stale existing-item intake preserves the newer file, then retry succeeds" do
    source = source_fixture()
    video_id = "stale_vid_#{System.unique_integer([:positive])}"
    item = media_item_fixture(%{source_id: source.id, media_id: video_id, media_filepath: nil})

    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "original\n", :missing)
    assert {:ok, %{version: old_version}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "newer\n", :any)

    assert {:error, :stale_conflict} =
             Intake.download_video(video_id, source.media_profile_id, %{
               "yt_dlp_options" => "--draft\n",
               "yt_dlp_options_version" => old_version
             })

    assert {:ok, %{contents: "newer\n", version: current_version}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert [] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})

    assert {:ok, :queued} =
             Intake.download_video(video_id, source.media_profile_id, %{
               "yt_dlp_options" => "--draft\n",
               "yt_dlp_options_version" => current_version
             })

    assert {:ok, %{contents: "--draft\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})
  end

  test "W07: a filter rejection is permanent and an explicit corrected retry downloads" do
    item = media_item_fixture(%{media_filepath: nil})
    message = "yt-dlp skipped this media item: 2021-01-12 upload date is not in range 0001-01-01 to 2020-01-11"

    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "--datebefore 20200101\n", :missing)
    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)

    expect(YtDlpRunnerMock, :run, fn
      _url, :download, _opts, _template, _addl -> {:skipped, message}
    end)

    assert {:ok, :non_retry} = perform_job(MediaDownloadWorker, %{id: item.id})
    assert Repo.reload!(item).error_type == :permanent
    assert Repo.reload!(item).last_error == message

    assert {:ok, _item} =
             Media.update_media_item_with_yt_dlp_options(
               item,
               %{},
               yt_dlp_options: {:present, "--retries 1\n"},
               yt_dlp_options_version: :any
             )

    expect(YtDlpRunnerMock, :run, 2, fn
      _url, :download, _opts, _template, _addl -> {:ok, render_metadata(:media_metadata)}
      _url, :download_thumbnail, _opts, _template, _addl -> {:ok, ""}
    end)

    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

    assert :ok = perform_job(MediaDownloadWorker, %{id: item.id, force: true, reset_last_error: true})
  end

  test "R01/R10: profile/source config failure rolls back the record and logs no contents" do
    Application.put_env(:pinchflat, :yt_dlp_config_file_fs, FailingFS)
    secret = "SUPER_SECRET_OPTION_MARKER"
    profile_name = "Failing profile #{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert {:error, %Ecto.Changeset{}, :eacces} =
                 Profiles.create_media_profile(
                   %{name: profile_name, output_path_template: "{{ title }}.%(ext)s"},
                   yt_dlp_options: {:present, "secret=#{secret}\n"}
                 )
      end)

    refute Repo.get_by(MediaProfile, name: profile_name)
    refute log =~ secret

    channel_id = "UC_failing_#{System.unique_integer([:positive])}"

    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _template, _addl ->
      {:ok, source_details_return_fixture(%{channel_id: channel_id, playlist_id: channel_id})}
    end)

    assert {:error, %Ecto.Changeset{}, :eacces} =
             Sources.create_source(
               %{
                 media_profile_id: media_profile_fixture().id,
                 source_type: :channel,
                 original_url: "https://www.youtube.com/channel/#{channel_id}"
               },
               yt_dlp_options: {:present, "secret=#{secret}\n"}
             )

    refute Repo.get_by(Source, collection_id: channel_id)
  end

  test "R02/R03/R05: pending options survive a failed write and replay without stale overwrite" do
    profile = media_profile_fixture()
    video_id = "dQw4w9WgXcQ"

    assert {:ok, :indexing} =
             Intake.download_video(video_id, profile.id, %{"yt_dlp_options" => "--pending\n"})

    source = Repo.get_by!(Source, collection_id: video_id, media_profile_id: profile.id)
    stub_video_index(video_id, source)

    Application.put_env(:pinchflat, :yt_dlp_config_file_fs, FailingFS)
    assert [_item] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    item = Repo.get_by!(MediaItem, source_id: source.id, media_id: video_id)

    assert {:ok, %{contents: "--pending\n"}} = PendingMediaItemOptions.fetch(source, video_id)
    refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})

    Application.delete_env(:pinchflat, :yt_dlp_config_file_fs)
    assert [_item] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)

    assert {:ok, %{contents: "--pending\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)
    assert {:ok, nil} = PendingMediaItemOptions.fetch(source, video_id)
    assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})

    assert {:ok, _item} =
             Media.update_media_item_with_yt_dlp_options(
               item,
               %{},
               yt_dlp_options: {:present, "--newer-edit\n"},
               yt_dlp_options_version: :any
             )

    assert {:ok, :none} = PendingMediaItemOptions.apply_for_item(item)
    assert {:ok, %{contents: "--newer-edit\n"}} = YtDlpConfigFile.read_scope(:media_item, item.id)

    assert [_] = SlowIndexingHelpers.index_and_enqueue_download_for_media_items(source)
    assert [_] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})
  end

  test "R06: duplicate intake refuses without changing the first pending payload" do
    profile = media_profile_fixture()
    video_id = "dQw4w9WgXcQ"

    assert {:ok, :indexing} =
             Intake.download_video(video_id, profile.id, %{"yt_dlp_options" => "--first\n"})

    source = Repo.get_by!(Source, collection_id: video_id)

    assert {:error, :already_queued} =
             Intake.download_video(video_id, profile.id, %{"yt_dlp_options" => "--second\n"})

    assert {:ok, %{contents: "--first\n"}} = PendingMediaItemOptions.fetch(source, video_id)
    assert Repo.aggregate(Source, :count, :id) == 1
    assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
  end

  test "R08: retargeting the source clears the pending item handoff" do
    profile = media_profile_fixture()
    other_profile = media_profile_fixture()
    video_id = "dQw4w9WgXcQ"

    assert {:ok, :indexing} =
             Intake.download_video(video_id, profile.id, %{"yt_dlp_options" => "--stale\n"})

    source = Repo.get_by!(Source, collection_id: video_id)

    assert {:ok, updated} =
             Sources.update_source(source, %{media_profile_id: other_profile.id}, run_post_commit_tasks: false)

    assert {:ok, nil} = PendingMediaItemOptions.fetch(updated, video_id)
  end

  test "R11: a later download attempt sees the updated item file" do
    source = source_fixture()
    item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
    assert {:ok, item_path} = YtDlpConfigFile.scope_path(:media_item, item.id)
    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "--old\n", :missing)

    stub(YtDlpRunnerMock, :run, fn
      _url, :download, _opts, _template, _addl ->
        send(self(), {:download_saw, File.read!(item_path)})
        {:ok, render_metadata(:media_metadata)}

      _url, :download_thumbnail, _opts, _template, _addl ->
        {:ok, ""}
    end)

    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

    assert :ok = perform_job(MediaDownloadWorker, %{id: item.id})
    assert_receive {:download_saw, "--old\n"}

    assert :ok = YtDlpConfigFile.save_scope(:media_item, item.id, "--new\n", :any)
    assert :ok = perform_job(MediaDownloadWorker, %{id: item.id, force: true})
    assert_receive {:download_saw, "--new\n"}
  end

  test "S03: migration hold blocks video intake before any source or handoff is written" do
    profile = media_profile_fixture()
    Application.put_env(:pinchflat, :postgres_migration_boot_held, true)

    assert {:error, :migration_hold_active} =
             Intake.download_video("dQw4w9WgXcQ", profile.id, %{"yt_dlp_options" => "--hold\n"})

    assert Repo.aggregate(Source, :count, :id) == 0
    assert Repo.aggregate(MediaItemOptionHandoff, :count, :id) == 0
  end

  defp stub_video_index(video_id, source) do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_media_attributes_for_collection, _opts, _output_template, _addl ->
        {:ok, Phoenix.json_library().encode!(video_metadata(video_id, source))}

      _url, :get_downloadable_status, _opts, _output_template, _addl ->
        {:ok, "{}"}

      _url, :predict_filepath_from_metadata, _opts, _output_template, _addl ->
        {:ok, Phoenix.json_library().encode!(%{"filename" => "/tmp/test/media/scoped-video.mp4"})}
    end)
  end

  defp stub_download_success(on_opts) do
    stub(YtDlpRunnerMock, :run, fn
      _url, :download, opts, _template, _addl ->
        on_opts.(opts)
        {:ok, render_metadata(:media_metadata)}

      _url, :download_thumbnail, _opts, _template, _addl ->
        {:ok, ""}

      _url, :get_downloadable_status, _opts, _template, _addl ->
        {:ok, "{}"}
    end)

    stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)
  end

  defp config_locations(opts) do
    for {:config_locations, path} <- opts, do: path
  end

  defp video_metadata(video_id, source) do
    %{
      "id" => video_id,
      "title" => "Scoped intake video",
      "original_url" => source.original_url,
      "webpage_url" => source.original_url,
      "live_status" => "not_live",
      "description" => "Scoped intake description",
      "aspect_ratio" => 1.67,
      "duration" => 12.34,
      "upload_date" => Date.utc_today() |> Date.add(-1) |> Calendar.strftime("%Y%m%d"),
      "availability" => "public"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:pinchflat, key)
  defp restore_env(key, value), do: Application.put_env(:pinchflat, key, value)
end
