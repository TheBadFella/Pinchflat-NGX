defmodule Pinchflat.FastIndexing.FastIndexingHelpersTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog
  import Pinchflat.TasksFixtures
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Tasks
  alias Pinchflat.Settings
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.FastIndexing.FastIndexingHelpers

  setup do
    stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
      {:ok, media_attributes_return_fixture()}
    end)

    {:ok, [source: source_fixture()]}
  end

  describe "kickoff_indexing_task/1" do
    test "deletes any existing fast indexing tasks", %{source: source} do
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      assert Repo.reload!(task)
      assert {:ok, _} = FastIndexingHelpers.kickoff_indexing_task(source)
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "kicks off a new fast indexing task", %{source: source} do
      assert {:ok, _} = FastIndexingHelpers.kickoff_indexing_task(source)
      assert [worker] = all_enqueued(worker: FastIndexingWorker)
      assert worker.args["id"] == source.id
    end
  end

  describe "index_and_kickoff_downloads/1" do
    test "enqueues a worker for each new media_id in the source's RSS feed", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker] = all_enqueued(worker: MediaDownloadWorker)
      assert worker.args["id"] == media_item.id
      assert worker.priority == 0
    end

    test "does not enqueue a new worker for the source's media IDs we already know about", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      media_item_fixture(source_id: source.id, media_id: "test_1")

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "kicks off a download task for all pending media but at a lower priority", %{source: source} do
      pending_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker_1, _worker_2] = all_enqueued(worker: MediaDownloadWorker)
      assert worker_1.args["id"] == pending_item.id
      assert worker_1.priority == 1
    end

    test "returns the found media items", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "persists availability returned during fast indexing", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl_opts ->
        {:ok, media_attributes_return_fixture(%{availability: "subscriber_only"})}
      end)

      assert [%MediaItem{availability: :subscriber_only}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not enqueue media blocked by the source availability policy" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      source = source_fixture(%{download_members_only_media: false})

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl_opts ->
        {:ok, media_attributes_return_fixture(%{availability: "subscriber_only"})}
      end)

      assert [%MediaItem{availability: :subscriber_only, prevent_download: true, download_prevented_reason: :policy}] =
               FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not enqueue a download job if the source does not allow it" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      source = source_fixture(%{download_media: false})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "creates a download task record", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [_] = Tasks.list_tasks_for(media_item, "MediaDownloadWorker")
    end

    test "passes the source's download options to the yt-dlp runner", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, opts, _ot, _addl_opts ->
        assert {:output, "/tmp/test/media/%(title)S.%(ext)S"} in opts
        assert {:remux_video, "mp4"} in opts
        {:ok, media_attributes_return_fixture()}
      end)

      FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "passes the source player client to the yt-dlp runner" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, opts, _ot, _addl_opts ->
        assert {:extractor_args, "youtube:player-client=android"} in opts
        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{player_client: :android})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not enqueue a download job if the media item does not match the format rules" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      profile = media_profile_fixture(%{shorts_behaviour: :exclude})
      source = source_fixture(%{media_profile_id: profile.id})

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        output =
          Phoenix.json_library().encode!(%{
            id: "video2",
            title: "Video 2",
            original_url: "https://example.com/shorts/video2",
            live_status: "is_live",
            description: "desc2",
            aspect_ratio: 1.67,
            duration: 345.67,
            upload_date: "20210101"
          })

        {:ok, output}
      end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not blow up if a media item cannot be created", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:ok, "{}"}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not blow up if a media item causes a yt-dlp error", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:error, "message", 1}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "skips upcoming live events without logging an error", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:error, "ERROR: [youtube] test_1: This live event will begin in a few moments.\n", 1}
      end)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
          end)
        end)

      refute log =~ "Error creating media item"
      assert log =~ "Skipping transient live event"
    end
  end

  describe "index_and_kickoff_downloads/1 when testing the playlist owner lock" do
    test "indexes every upload but only enqueues the owner's when the lock is on" do
      source =
        source_fixture(%{
          collection_type: :playlist,
          fast_index: true,
          only_owner_uploads: true,
          owner_channel_id: "UC_owner_123"
        })

      expect(HTTPClientMock, :get, fn _url ->
        {:ok, "<yt:videoId>v_owner</yt:videoId><yt:videoId>v_foreign</yt:videoId>"}
      end)

      expect(YtDlpRunnerMock, :run, 2, fn url, :get_media_attributes, _opts, _ot, _addl ->
        cond do
          String.ends_with?(url, "v_owner") ->
            {:ok, media_attributes_return_fixture(%{id: "v_owner", channel_id: "UC_owner_123"})}

          String.ends_with?(url, "v_foreign") ->
            {:ok, media_attributes_return_fixture(%{id: "v_foreign", channel_id: "UC_other_456"})}
        end
      end)

      assert items = FastIndexingHelpers.index_and_kickoff_downloads(source)
      assert Enum.sort(Enum.map(items, & &1.media_id)) == ["v_foreign", "v_owner"]

      owner_item = Repo.get_by!(MediaItem, source_id: source.id, media_id: "v_owner")
      foreign_item = Repo.get_by!(MediaItem, source_id: source.id, media_id: "v_foreign")

      assert owner_item.channel_id == "UC_owner_123"
      assert foreign_item.channel_id == "UC_other_456"

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => owner_item.id})
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => foreign_item.id})
    end

    test "indexes every upload and enqueues both when the lock is off" do
      source =
        source_fixture(%{
          collection_type: :playlist,
          fast_index: true,
          only_owner_uploads: false,
          owner_channel_id: "UC_owner_123"
        })

      expect(HTTPClientMock, :get, fn _url ->
        {:ok, "<yt:videoId>v_owner</yt:videoId><yt:videoId>v_foreign</yt:videoId>"}
      end)

      expect(YtDlpRunnerMock, :run, 2, fn url, :get_media_attributes, _opts, _ot, _addl ->
        cond do
          String.ends_with?(url, "v_owner") ->
            {:ok, media_attributes_return_fixture(%{id: "v_owner", channel_id: "UC_owner_123"})}

          String.ends_with?(url, "v_foreign") ->
            {:ok, media_attributes_return_fixture(%{id: "v_foreign", channel_id: "UC_other_456"})}
        end
      end)

      assert items = FastIndexingHelpers.index_and_kickoff_downloads(source)
      assert Enum.sort(Enum.map(items, & &1.media_id)) == ["v_foreign", "v_owner"]

      owner_item = Repo.get_by!(MediaItem, source_id: source.id, media_id: "v_owner")
      foreign_item = Repo.get_by!(MediaItem, source_id: source.id, media_id: "v_foreign")

      assert owner_item.channel_id == "UC_owner_123"
      assert foreign_item.channel_id == "UC_other_456"

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => owner_item.id})
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => foreign_item.id})
    end
  end

  describe "index_and_kickoff_downloads/1 when testing cookies" do
    test "fast indexing completes the download after cookie recovery with artwork disabled" do
      profile = media_profile_fixture(download_source_images: false, download_nfo: false)
      source = source_fixture(cookie_behaviour: :when_needed, fast_index: true, media_profile_id: profile.id)
      path = Path.join(Application.get_env(:pinchflat, :media_directory), "cookie-recovery/Recovered video.mp4")
      metadata = render_parsed_metadata(:media_metadata)

      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>video1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _template, addl ->
        refute addl[:use_cookies]
        {:error, "Sign in to confirm you're not a bot", 1}
      end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _template, addl ->
        assert addl[:use_cookies]
        {:ok, media_attributes_return_fixture(%{id: "video1", title: "Recovered video", filename: path})}
      end)

      stub(UserScriptRunnerMock, :run, fn _event, _data -> {:ok, "", 0} end)
      stub(AppriseRunnerMock, :run, fn _server, _opts -> {:ok, ""} end)

      assert {:ok, _} = perform_job(FastIndexingWorker, %{id: source.id})
      assert [job] = all_enqueued(worker: MediaDownloadWorker)
      item = Repo.get!(MediaItem, job.args["id"])
      assert item.title == "Recovered video"
      assert item.predicted_media_filepath == path

      stub(YtDlpRunnerMock, :run, fn
        _url, :download, _opts, _template, _addl ->
          File.mkdir_p!(Path.dirname(path))
          File.cp!(media_filepath_fixture(), path)

          {:ok,
           Jason.encode!(Map.merge(metadata, %{"id" => "video1", "title" => "Recovered video", "filepath" => path}))}

        _url, :download_thumbnail, _opts, _template, _addl ->
          {:ok, ""}
      end)

      assert :ok = perform_job(MediaDownloadWorker, job.args)
      completed = Repo.reload!(item)
      assert completed.title == "Recovered video"
      assert completed.media_filepath == path
      assert completed.media_downloaded_at
      assert File.read!(path) == File.read!(media_filepath_fixture())

      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>video1</yt:videoId>"} end)
      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
      assert Repo.aggregate(MediaItem, :count) == 1
    end

    test "retries authentication failures once with cookies and persists the new video" do
      source = source_fixture(cookie_behaviour: :when_needed)
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>video1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes, opts, template, addl ->
        refute addl[:use_cookies]
        send(self(), {:metadata_request, url, opts, template})
        {:error, "Sign in to confirm you're not a bot", 1}
      end)

      expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes, opts, template, addl ->
        assert addl[:use_cookies]
        assert_received {:metadata_request, ^url, ^opts, ^template}
        {:ok, media_attributes_return_fixture(%{filename: "/tmp/test/media/Video 1.mp4"})}
      end)

      assert [item] = FastIndexingHelpers.index_and_kickoff_downloads(source)
      assert Repo.reload!(item).title == "Video 1"
      assert item.predicted_media_filepath == "/tmp/test/media/Video 1.mp4"
      assert_enqueued(worker: MediaDownloadWorker, args: %{id: item.id})
    end

    for {policy, message} <- [
          {:disabled, "Sign in to confirm you're not a bot"},
          {:all_operations, "Sign in to confirm you're not a bot"},
          {:when_needed, "HTTP Error 429: Too Many Requests"},
          {:when_needed, "Video unavailable"}
        ] do
      test "does not retry #{policy} metadata requests after #{message}" do
        source = source_fixture(cookie_behaviour: unquote(policy))
        expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>video1</yt:videoId>"} end)

        expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _template, addl ->
          assert addl[:use_cookies] == (unquote(policy) == :all_operations)
          {:error, unquote(message), 1}
        end)

        assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
        refute_enqueued(worker: MediaDownloadWorker)
      end
    end

    test "does not loop when the authenticated retry also fails" do
      source = source_fixture(cookie_behaviour: :when_needed)
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>video1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, 2, fn _url, :get_media_attributes, _opts, _template, _addl ->
        {:error, "This video is available to this channel's members", 1}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "sets use_cookies if the source uses cookies" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, true} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :all_operations})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, false} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not set use_cookies if the source does not use cookies" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, false} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :disabled})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 when testing backends" do
    test "uses the YouTube API if it is enabled", %{source: source} do
      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "https://youtube.googleapis.com/youtube/v3/playlistItems"

        {:ok, "{}"}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "the YouTube API creates records as expected", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers ->
        {:ok, ~s({ "items": [ {"contentDetails": {"videoId": "test_1"}} ] })}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "RSS is used as a backup if the API fails", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, ""} end)
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      Settings.set(youtube_api_key: "test_key")

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "RSS is used if the API is not enabled", %{source: source} do
      expect(HTTPClientMock, :get, fn url ->
        assert url =~ "https://www.youtube.com/feeds/videos.xml"

        {:ok, "<yt:videoId>test_1</yt:videoId>"}
      end)

      Settings.set(youtube_api_key: nil)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 when translating titles" do
    test "stores the translated title when the listing title differs from the canonical title" do
      source = source_fixture(%{title_language: "de"})
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_translated_titles, opts, _template, _addl ->
          assert {:playlist_end, 30} in opts
          {:ok, translated_titles_output(%{"video1" => "Titel Eins"})}

        _url, :get_media_attributes, _opts, _template, _addl ->
          {:ok, media_attributes_return_fixture()}
      end)

      assert [%MediaItem{translated_title: "Titel Eins"} = item] =
               FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert item.title == "Video 1"
    end

    test "does not fetch the listing when there are no new media ids" do
      source = source_fixture(%{title_language: "de"})
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      media_item_fixture(source_id: source.id, media_id: "test_1")

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_translated_titles, _opts, _template, _addl ->
          flunk("should not fetch translated titles when there are no new media ids")

        _url, :get_media_attributes, _opts, _template, _addl ->
          {:ok, media_attributes_return_fixture()}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not fetch the listing when title_language is nil" do
      source = source_fixture(%{title_language: nil})
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_translated_titles, _opts, _template, _addl ->
          flunk("should not fetch translated titles when title_language is nil")

        _url, :get_media_attributes, _opts, _template, _addl ->
          {:ok, media_attributes_return_fixture()}
      end)

      assert [%MediaItem{translated_title: nil}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  defp translated_titles_output(titles) do
    titles
    |> Enum.map_join("\n", fn {media_id, title} ->
      Phoenix.json_library().encode!(%{id: media_id, title: title})
    end)
  end

  defp with_debug_logs(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end
end
