defmodule Pinchflat.Downloading.MediaDownloaderFallbackTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Downloading.MediaDownloader

  setup do
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)
    :ok
  end

  describe "client_fallback_eligible_error?/1" do
    test "returns true for YouTube client / auth challenge errors" do
      assert MediaDownloader.client_fallback_eligible_error?("ERROR: [youtube] HTTP Error 403: Forbidden")
      assert MediaDownloader.client_fallback_eligible_error?("Sign in to confirm you’re not a bot")
      assert MediaDownloader.client_fallback_eligible_error?("Sign in to confirm you're not a bot")
      assert MediaDownloader.client_fallback_eligible_error?("This video is not available on this client")
      assert MediaDownloader.client_fallback_eligible_error?("Sign in to view this video")
      assert MediaDownloader.client_fallback_eligible_error?("Confirm your age to view this video")
      assert MediaDownloader.client_fallback_eligible_error?("Use --cookies to authenticate")
    end

    test "returns false for non-fallback errors" do
      refute MediaDownloader.client_fallback_eligible_error?("HTTP Error 429: Too Many Requests")
      refute MediaDownloader.client_fallback_eligible_error?("Rate-limit reached, slow down")
      refute MediaDownloader.client_fallback_eligible_error?("ERROR: Private video")
      refute MediaDownloader.client_fallback_eligible_error?("This video has been removed")
      refute MediaDownloader.client_fallback_eligible_error?("Join this channel to get access to members-only content")

      refute MediaDownloader.client_fallback_eligible_error?(
               "The uploader has not made this video available in your country"
             )

      refute MediaDownloader.client_fallback_eligible_error?("Requested format is not available")
      refute MediaDownloader.client_fallback_eligible_error?("No space left on device")
      refute MediaDownloader.client_fallback_eligible_error?("Permission denied")
      refute MediaDownloader.client_fallback_eligible_error?(nil)
      refute MediaDownloader.client_fallback_eligible_error?(:some_atom)
    end
  end

  describe "DownloadOptionBuilder client overrides" do
    test "respects client_override argument in build_youtube_options_for and build_player_client_options_for" do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id, player_client: :ios})

      # Without override, uses source's primary client (:ios)
      assert [{:extractor_args, "youtube:player-client=ios"}] =
               DownloadOptionBuilder.build_player_client_options_for(source)

      # With override, uses the overridden client (:android)
      assert [{:extractor_args, "youtube:player-client=android"}] =
               DownloadOptionBuilder.build_player_client_options_for(source, :android)

      # With nil override, falls back to source primary (:ios)
      assert [{:extractor_args, "youtube:player-client=ios"}] =
               DownloadOptionBuilder.build_player_client_options_for(source, nil)
    end

    test "respects player_client option in build/2" do
      profile = media_profile_fixture()
      source = source_fixture(%{media_profile_id: profile.id, player_client: :ios})
      media_item = Repo.preload(media_item_fixture(source_id: source.id), source: :media_profile)

      assert {:ok, opts_primary} = DownloadOptionBuilder.build(media_item)
      assert {:extractor_args, "youtube:player-client=ios"} in opts_primary

      assert {:ok, opts_fallback} = DownloadOptionBuilder.build(media_item, player_client: :android)
      assert {:extractor_args, "youtube:player-client=android"} in opts_fallback
      refute {:extractor_args, "youtube:player-client=ios"} in opts_fallback
    end
  end

  describe "MediaDownloader fallback execution" do
    test "sequentially falls back to next client when primary fails with HTTP 403" do
      profile = media_profile_fixture()

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          player_client: :ios,
          player_client_fallbacks: ["android", "tv"],
          cookie_behaviour: :disabled
        })

      media_item = Repo.preload(media_item_fixture(source_id: source.id), [:metadata, source: :media_profile])

      call_count = :atomics.new(1, [])

      expect(YtDlpRunnerMock, :run, 5, fn _url, operation, opts, _ot, _addl ->
        count = :atomics.add_get(call_count, 1, 1)

        case {operation, count} do
          # First attempt: status check passes
          {:get_downloadable_status, 1} ->
            {:ok, "{}"}

          # First attempt download: primary client (:ios) fails with 403
          {:download, 2} ->
            assert {:extractor_args, "youtube:player-client=ios"} in opts
            {:error, "ERROR: [youtube] HTTP Error 403: Forbidden", 1}

          # Second attempt: status check for fallback client (:android)
          {:get_downloadable_status, 3} ->
            {:ok, "{}"}

          # Second attempt download: fallback client (:android) succeeds
          {:download, 4} ->
            assert {:extractor_args, "youtube:player-client=android"} in opts
            {:ok, render_metadata(:media_metadata)}

          # Thumbnail download after successful media download
          {:download_thumbnail, _} ->
            {:ok, ""}
        end
      end)

      # Staging scratch file
      staging_dir = Path.join(System.tmp_dir!(), "pinchflat_test_staging_#{media_item.id}")
      File.mkdir_p!(staging_dir)
      test_scratch = Path.join(staging_dir, "partial.part")
      File.write!(test_scratch, "partial bytes")

      assert {:ok, updated_media_item} =
               MediaDownloader.download_for_media_item(
                 media_item,
                 staging_directory: staging_dir,
                 skip_download_precheck: false
               )

      assert updated_media_item.availability == :public
      # Verify scratch partial file was preserved for resumption in attempt 2
      assert File.exists?(test_scratch)

      File.rm_rf(staging_dir)
    end

    test "stops immediately and does not try fallbacks on non-eligible errors (e.g., HTTP 429)" do
      profile = media_profile_fixture()

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          player_client: :ios,
          player_client_fallbacks: ["android", "tv"],
          cookie_behaviour: :disabled
        })

      media_item = Repo.preload(media_item_fixture(source_id: source.id), [:metadata, source: :media_profile])

      # Exactly 2 calls: status check, then download attempt with primary :ios.
      # Because 429 is not fallback-eligible, no further calls are made!
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert {:extractor_args, "youtube:player-client=ios"} in opts
          {:error, "HTTP Error 429: Too Many Requests", 1}
      end)

      assert {:error, :download_failed, msg} = MediaDownloader.download_for_media_item(media_item)
      assert msg =~ "HTTP Error 429: Too Many Requests"
    end

    test "exhausts all clients in chain and returns error when all fail" do
      profile = media_profile_fixture()

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          player_client: :ios,
          player_client_fallbacks: ["android"],
          cookie_behaviour: :disabled
        })

      media_item = Repo.preload(media_item_fixture(source_id: source.id), [:metadata, source: :media_profile])

      call_count = :atomics.new(1, [])

      # 4 calls:
      # 1. status check for :ios
      # 2. download for :ios (fails with 403)
      # 3. status check for :android
      # 4. download for :android (fails with bot detection)
      expect(YtDlpRunnerMock, :run, 4, fn _url, operation, opts, _ot, _addl ->
        count = :atomics.add_get(call_count, 1, 1)

        case {operation, count} do
          {:get_downloadable_status, 1} ->
            {:ok, "{}"}

          {:download, 2} ->
            assert {:extractor_args, "youtube:player-client=ios"} in opts
            {:error, "ERROR: [youtube] HTTP Error 403: Forbidden", 1}

          {:get_downloadable_status, 3} ->
            {:ok, "{}"}

          {:download, 4} ->
            assert {:extractor_args, "youtube:player-client=android"} in opts
            {:error, "Sign in to confirm you're not a bot", 1}
        end
      end)

      assert {:error, :download_failed, msg} = MediaDownloader.download_for_media_item(media_item)
      assert msg =~ "Sign in to confirm you're not a bot"
    end

    test "aborts fallback recursion if media item is cancelled or removed before next attempt" do
      profile = media_profile_fixture()

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          player_client: :ios,
          player_client_fallbacks: ["android"],
          cookie_behaviour: :disabled
        })

      media_item = Repo.preload(media_item_fixture(source_id: source.id), [:metadata, source: :media_profile])

      # First attempt fails with 403, and during the failure we mark media_item as culled
      expect(YtDlpRunnerMock, :run, 2, fn _url, operation, _opts, _ot, _addl ->
        case operation do
          :get_downloadable_status ->
            {:ok, "{}"}

          :download ->
            # Mark media item culled before fallback is attempted
            Pinchflat.Media.update_media_item(media_item, %{culled_at: DateTime.utc_now()})
            {:error, "ERROR: [youtube] HTTP Error 403: Forbidden", 1}
        end
      end)

      assert {:error, :cancelled, msg} = MediaDownloader.download_for_media_item(media_item)
      assert msg =~ "cancelled or media item removed"
    end

    test "aborts fallback recursion if linked Oban job is cancelled before next attempt" do
      profile = media_profile_fixture()

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          player_client: :ios,
          player_client_fallbacks: ["android"],
          cookie_behaviour: :disabled
        })

      media_item = Repo.preload(media_item_fixture(source_id: source.id), [:metadata, source: :media_profile])
      {:ok, job} = Repo.insert(Pinchflat.Downloading.MediaDownloadWorker.new(%{"id" => media_item.id}))

      expect(YtDlpRunnerMock, :run, 2, fn _url, operation, _opts, _ot, _addl ->
        case operation do
          :get_downloadable_status ->
            {:ok, "{}"}

          :download ->
            # Cancel the linked Oban job before fallback is attempted
            Oban.cancel_job(job.id)
            {:error, "ERROR: [youtube] HTTP Error 403: Forbidden", 1}
        end
      end)

      assert {:error, :cancelled, msg} =
               MediaDownloader.download_for_media_item(media_item, job_id: job.id)

      assert msg =~ "cancelled"
    end

    test "aborts fallback recursion if source media downloads are disabled before next attempt" do
      profile = media_profile_fixture()

      source =
        source_fixture(%{
          media_profile_id: profile.id,
          player_client: :ios,
          player_client_fallbacks: ["android"],
          cookie_behaviour: :disabled
        })

      media_item = Repo.preload(media_item_fixture(source_id: source.id), [:metadata, source: :media_profile])

      expect(YtDlpRunnerMock, :run, 2, fn _url, operation, _opts, _ot, _addl ->
        case operation do
          :get_downloadable_status ->
            {:ok, "{}"}

          :download ->
            # Disable source downloads before fallback is attempted
            Pinchflat.Sources.update_source(source, %{download_media: false})
            {:error, "ERROR: [youtube] HTTP Error 403: Forbidden", 1}
        end
      end)

      assert {:error, :cancelled, msg} = MediaDownloader.download_for_media_item(media_item)
      assert msg =~ "Source media downloads disabled"
    end
  end
end
