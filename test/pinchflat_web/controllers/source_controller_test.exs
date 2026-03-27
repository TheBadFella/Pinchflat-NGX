defmodule PinchflatWeb.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Tasks

  setup do
    media_profile = media_profile_fixture()
    Settings.set(onboarding: false)

    extras_directory =
      Path.join(System.tmp_dir!(), "pinchflat-source-controller-cookie-tests-#{System.unique_integer([:positive])}")

    original_directory = Application.get_env(:pinchflat, :extras_directory)

    Application.put_env(:pinchflat, :extras_directory, extras_directory)
    File.mkdir_p!(extras_directory)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original_directory)
      File.rm_rf!(extras_directory)
    end)

    {:ok,
     %{
       create_attrs: %{
         media_profile_id: media_profile.id,
         collection_type: "channel",
         original_url: "https://www.youtube.com/@pinchflattest"
       },
       update_attrs: %{
         original_url: "https://www.youtube.com/playlist?list=PL1234567890ABCDEF"
       },
       invalid_attrs: %{original_url: nil, media_profile_id: nil},
       extras_directory: extras_directory
     }}
  end

  describe "index" do
    # Most of the tests are in `index_table_list_test.exs`
    test "returns 200", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert html_response(conn, 200) =~ "Sources"
    end

    test "renders download mode identifiers for automatic and delayed playlists", %{conn: conn} do
      source_fixture(%{custom_name: "Automatic Source", collection_type: :playlist, selection_mode: :all})
      source_fixture(%{custom_name: "Delayed Source", collection_type: :playlist, selection_mode: :manual})

      conn = get(conn, ~p"/sources")
      response = html_response(conn, 200)

      assert response =~ "Automatic Downloads"
      assert response =~ "Delayed Downloads"
    end

    test "renders source row controls", %{conn: conn} do
      source_fixture(%{custom_name: "Controllable Source"})

      conn = get(conn, ~p"/sources")
      response = html_response(conn, 200)

      assert response =~ "Start all"
      assert response =~ "Pause all"
      assert response =~ "Stop all"
      assert response =~ "Start downloads for Controllable Source?"
      assert response =~ "Pause downloads for Controllable Source?"
      assert response =~ "Stop downloads for Controllable Source?"
    end
  end

  describe "new source" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/sources/new")
      assert html_response(conn, 200) =~ "New Source"
      assert html_response(conn, 200) =~ "Delay Automatic Download"
      assert html_response(conn, 200) =~ "How source folders work"
      assert html_response(conn, 200) =~ "Insert media profile template"
    end

    test "renders source folder picker options from existing media directories", %{conn: conn} do
      media_root = Path.join(System.tmp_dir!(), "pinchflat-source-folder-picker-#{System.unique_integer([:positive])}")
      original_media_root = Application.get_env(:pinchflat, :media_directory)

      Application.put_env(:pinchflat, :media_directory, media_root)
      File.mkdir_p!(Path.join([media_root, "Kids", "Bluey"]))

      on_exit(fn ->
        Application.put_env(:pinchflat, :media_directory, original_media_root)
        File.rm_rf!(media_root)
      end)

      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ "Pick existing source folder"
      assert response =~ "Kids"
      assert response =~ "Kids/Bluey"
    end

    test "renders cookie management controls", %{conn: conn} do
      File.write!(Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt"), "youtube-cookie-data")

      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ "Upload cookies.txt"
      assert response =~ "Paste Cookie Contents"
      assert response =~ "Inspect Cookie File"
      assert response =~ "Cookie file is configured and ready to use."
    end

    test "defaults cookie behaviour to all operations when cookies.txt exists", %{conn: conn} do
      File.write!(Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt"), "youtube-cookie-data")

      conn = get(conn, ~p"/sources/new")
      response = html_response(conn, 200)

      assert response =~ ~r/<input[^>]*type="hidden"[^>]*name="source\[cookie_behaviour\]"[^>]*value="all_operations"/
    end

    test "renders correct layout when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = get(conn, ~p"/sources/new")

      refute html_response(conn, 200) =~ "MENU"
    end

    test "preloads some attributes when using a template", %{conn: conn} do
      source = source_fixture(custom_name: "My first source", download_cutoff_date: "2021-01-01")

      conn = get(conn, ~p"/sources/new", %{"template_id" => source.id})
      assert html_response(conn, 200) =~ "New Source"
      assert html_response(conn, 200) =~ "2021-01-01"
      refute html_response(conn, 200) =~ source.custom_name
    end
  end

  describe "create source" do
    test "redirects to show when data is valid", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}"

      conn = get(conn, ~p"/sources/#{id}")
      assert html_response(conn, 200) =~ "Source"
    end

    test "renders errors when data is invalid", %{conn: conn, invalid_attrs: invalid_attrs} do
      conn = post(conn, ~p"/sources", source: invalid_attrs)
      assert html_response(conn, 200) =~ "New Source"
    end

    test "redirects to onboarding when onboarding", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert redirected_to(conn) == ~p"/?onboarding=1"
    end

    test "redirects to show for a single video URL", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           id: "72maj9FLQZI",
           title: "One-Off Video",
           channel: "PinchflatTestChannel",
           channel_id: "UCQH2",
           playlist_id: nil,
           playlist_title: nil,
           filename: "/tmp/test/media/one-off.mp4"
         })}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            media_profile_id: media_profile_fixture().id,
            original_url: "https://www.youtube.com/watch?v=72maj9FLQZI"
          }
        )

      assert %{id: _id} = redirected_params(conn)
    end

    test "redirects playlists with delayed automatic download to the selection tab", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: nil,
           channel_id: nil,
           playlist_id: "some_playlist_id_123",
           playlist_title: "Some Playlist"
         })}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            media_profile_id: media_profile_fixture().id,
            original_url: "https://www.youtube.com/playlist?list=PL1234567890ABCDEF",
            delay_automatic_download: "true"
          }
        )

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}?#{[tab: "selection"]}"
    end

    test "redirects normal playlists to the source page and leaves auto download enabled", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: nil,
           channel_id: nil,
           playlist_id: "some_playlist_id_123",
           playlist_title: "Some Playlist"
         })}
      end)

      conn =
        post(conn, ~p"/sources",
          source: %{
            media_profile_id: media_profile_fixture().id,
            original_url: "https://www.youtube.com/playlist?list=PL1234567890ABCDEF"
          }
        )

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}"

      source = Pinchflat.Sources.get_source!(id)
      assert source.selection_mode == :all
      assert source.download_media
    end

    test "renders correct layout on error when onboarding", %{conn: conn, invalid_attrs: invalid_attrs} do
      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: invalid_attrs)

      refute html_response(conn, 200) =~ "MENU"
    end
  end

  describe "edit source" do
    setup [:create_source]

    test "renders form for editing chosen source", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/edit")
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end

    test "renders restore automatic downloads action for manual playlists", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      conn = get(conn, ~p"/sources/#{source}/edit")

      assert html_response(conn, 200) =~ "Restore Automatic Downloads"
    end

    test "does not override saved cookie behaviour on edit when cookies.txt exists", %{conn: conn, source: source} do
      File.write!(Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt"), "youtube-cookie-data")
      source = Repo.reload!(source)

      conn = get(conn, ~p"/sources/#{source}/edit")
      response = html_response(conn, 200)

      assert response =~ ~r/<input[^>]*type="hidden"[^>]*name="source\[cookie_behaviour\]"[^>]*value="disabled"/
      refute response =~ ~r/<input[^>]*type="hidden"[^>]*name="source\[cookie_behaviour\]"[^>]*value="all_operations"/
    end
  end

  describe "cookie file actions" do
    test "save_cookies writes cookie contents and redirects back", %{conn: conn, extras_directory: extras_directory} do
      conn =
        post(conn, ~p"/sources/cookies/save", %{
          "cookies" => %{"contents" => "youtube-cookie-data"},
          "return_to" => "/sources/new"
        })

      assert redirected_to(conn) == "/sources/new"
      assert File.read!(Path.join(extras_directory, "cookies.txt")) == "youtube-cookie-data"
    end

    test "upload_cookies copies the uploaded file and redirects back", %{conn: conn, extras_directory: extras_directory} do
      upload_path = Path.join(extras_directory, "uploaded-cookies.txt")
      File.write!(upload_path, "uploaded-youtube-cookie-data")

      upload = %Plug.Upload{
        path: upload_path,
        filename: "cookies.txt",
        content_type: "text/plain"
      }

      conn = post(conn, ~p"/sources/cookies/upload", %{"cookies" => %{"file" => upload}, "return_to" => "/sources/new"})

      assert redirected_to(conn) == "/sources/new"
      assert File.read!(Path.join(extras_directory, "cookies.txt")) == "uploaded-youtube-cookie-data"
    end
  end

  describe "update source" do
    setup [:create_source]

    test "redirects when data is valid", %{conn: conn, source: source, update_attrs: update_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn = put(conn, ~p"/sources/#{source}", source: update_attrs)
      assert redirected_to(conn) == ~p"/sources/#{source}"

      conn = get(conn, ~p"/sources/#{source}")
      assert html_response(conn, 200) =~ "https://www.youtube.com/playlist?list=PL1234567890ABCDEF"
    end

    test "renders errors when data is invalid", %{
      conn: conn,
      source: source,
      invalid_attrs: invalid_attrs
    } do
      conn = put(conn, ~p"/sources/#{source}", source: invalid_attrs)
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end
  end

  describe "delete source in all cases" do
    setup [:create_source]

    test "redirects to the sources page", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}")
      assert redirected_to(conn) == ~p"/sources"
    end

    test "sets marked_for_deletion_at", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")
      assert Repo.reload!(source).marked_for_deletion_at
    end
  end

  describe "delete source when just deleting the records" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")

      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "delete source when deleting the records and files" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}?delete_files=true")

      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "force_download_pending" do
    test "enqueues pending download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert [%{args: %{"reset_last_error" => true}}] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "show source" do
    test "renders delayed download summary for manual playlists", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      conn = get(conn, ~p"/sources/#{source}")
      response = html_response(conn, 200)

      assert response =~ "Mode: Delayed"
      assert response =~ "Restore Automatic Downloads"
      assert response =~ "manual selection mode"
    end

    test "renders start, pause, and stop actions in the source actions dropdown", %{conn: conn} do
      source = source_fixture(%{custom_name: "Dropdown Source"})

      conn = get(conn, ~p"/sources/#{source}")
      response = html_response(conn, 200)

      assert response =~ "Start All"
      assert response =~ "Pause All"
      assert response =~ "Stop All"
      assert response =~ "Start downloads for Dropdown Source?"
      assert response =~ "Pause downloads for Dropdown Source?"
      assert response =~ "Stop downloads for Dropdown Source?"
    end

    test "renders the excluded tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Excluded"
    end

    test "renders the active tasks tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Active Tasks"
    end

    test "renders the job queue tab label", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Job Queue"
    end

    test "renders the selection tab label for manual playlists", %{conn: conn} do
      source = source_fixture(collection_type: :playlist, selection_mode: :manual)

      conn = get(conn, ~p"/sources/#{source}")

      assert html_response(conn, 200) =~ "Selection"
    end

    test "does not render the selection tab label for normal playlists", %{conn: conn} do
      source = source_fixture(collection_type: :playlist, selection_mode: :all)

      conn = get(conn, ~p"/sources/#{source}")

      refute html_response(conn, 200) =~ "Selection"
    end
  end

  describe "source row actions" do
    test "start_all enables the source and enqueues pending downloads", %{conn: conn} do
      source = source_fixture(%{enabled: false, download_media: false})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      conn = post(conn, ~p"/sources/#{source.id}/start_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Repo.reload!(source).enabled
      assert Repo.reload!(source).download_media
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "start_all reports when there is nothing to download", %{conn: conn} do
      source = source_fixture(%{enabled: false, download_media: false})

      conn = post(conn, ~p"/sources/#{source.id}/start_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Nothing to download for this source."
      refute Repo.reload!(source).enabled
      refute Repo.reload!(source).download_media
    end

    test "pause_all disables automatic downloads for the source", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      Pinchflat.Downloading.DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      conn = post(conn, ~p"/sources/#{source.id}/pause_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).download_media
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "pause_all cancels executing download tasks for the source", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "executing"])

      conn = post(conn, ~p"/sources/#{source.id}/pause_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).download_media
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
      assert Repo.get!(Oban.Job, task.job_id).state == "cancelled"
    end

    test "pause_all reports when there are no active downloads", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item_fixture(%{source_id: source.id, media_filepath: nil})

      conn = post(conn, ~p"/sources/#{source.id}/pause_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "No active downloads to pause for this source."
      assert Repo.reload!(source).download_media
    end

    test "stop_all disables the source and clears pending download jobs", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      Pinchflat.Downloading.DownloadingHelpers.enqueue_pending_download_tasks(source)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      conn = post(conn, ~p"/sources/#{source.id}/stop_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).enabled
      refute Repo.reload!(source).download_media
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "stop_all cancels executing download tasks for the source", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

      Oban.Job
      |> where([j], j.id == ^task.job_id)
      |> Repo.update_all(set: [state: "executing"])

      conn = post(conn, ~p"/sources/#{source.id}/stop_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      refute Repo.reload!(source).enabled
      refute Repo.reload!(source).download_media
      assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(task.id) end
      assert Repo.get!(Oban.Job, task.job_id).state == "cancelled"
    end

    test "stop_all reports when there is nothing to stop", %{conn: conn} do
      source = source_fixture(%{enabled: true, download_media: true})

      conn = post(conn, ~p"/sources/#{source.id}/stop_all", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Nothing to stop for this source."
      assert Repo.reload!(source).enabled
      assert Repo.reload!(source).download_media
    end
  end

  describe "restore_automatic_downloads" do
    test "restores automatic downloads for a manual playlist source", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})
      media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})

      conn = post(conn, ~p"/sources/#{source.id}/restore_automatic_downloads", %{"return_to" => "/sources"})

      assert redirected_to(conn) == "/sources"
      assert Repo.reload!(source).selection_mode == :all
      assert Repo.reload!(source).download_media
      refute Repo.reload!(media_item).prevent_download
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end
  end

  describe "apply_selection" do
    test "saves a manual playlist selection", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})
      selected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})
      unselected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: false})

      conn =
        post(conn, ~p"/sources/#{source}/apply_selection", %{
          "selected_media_ids" => [Integer.to_string(selected.id)],
          "selection_action" => "save"
        })

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "selection"]}"
      refute Repo.reload!(selected).prevent_download
      assert Repo.reload!(unselected).prevent_download
      refute Repo.reload!(source).download_media
    end

    test "download action enables downloads and enqueues selected items", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})
      selected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true})
      _unselected = media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: false})

      conn =
        post(conn, ~p"/sources/#{source}/apply_selection", %{
          "selected_media_ids" => [Integer.to_string(selected.id)],
          "selection_action" => "download"
        })

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "selection"]}"
      assert Repo.reload!(source).download_media
      assert [%{args: %{"id" => selected_id}}] = all_enqueued(worker: MediaDownloadWorker)
      assert selected_id == selected.id
    end

    test "range input selects matching playlist indexes", %{conn: conn} do
      source = source_fixture(%{collection_type: :playlist, selection_mode: :manual, download_media: false})

      first =
        media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true, playlist_index: 1})

      second =
        media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true, playlist_index: 2})

      third =
        media_item_fixture(%{source_id: source.id, media_filepath: nil, prevent_download: true, playlist_index: 3})

      conn =
        post(conn, ~p"/sources/#{source}/apply_selection", %{
          "selection_range" => "1-2",
          "selection_action" => "save"
        })

      assert redirected_to(conn) == ~p"/sources/#{source}?#{[tab: "selection"]}"
      refute Repo.reload!(first).prevent_download
      refute Repo.reload!(second).prevent_download
      assert Repo.reload!(third).prevent_download
    end
  end

  describe "force_redownload" do
    test "enqueues re-download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id, media_downloaded_at: now())

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_index" do
    test "forces an index", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "forces an index even if one wouldn't normally run", %{conn: conn} do
      source = source_fixture(index_frequency_minutes: 0, last_indexed_at: DateTime.utc_now())

      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args == %{"id" => source.id, "force" => true}
    end

    test "deletes pending indexing tasks", %{conn: conn} do
      source = source_fixture()
      {:ok, task} = MediaCollectionIndexingWorker.kickoff_with_task(source)
      job = Repo.preload(task, :job).job

      assert job.state == "available"
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert Repo.reload!(job).state == "cancelled"
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_index")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_metadata_refresh" do
    test "forces a metadata refresh", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
      post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert [_] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "sync_files_on_disk" do
    test "forces a file sync", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: FileSyncingWorker)
      post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert [_] = all_enqueued(worker: FileSyncingWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  defp create_source(_) do
    source = source_fixture()
    media_item = media_item_with_attachments(%{source_id: source.id})

    %{source: source, media_item: media_item}
  end

  defp runner_function_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {
      :ok,
      Phoenix.json_library().encode!(%{
        channel: "some channel name",
        channel_id: "some_channel_id_#{:rand.uniform(1_000_000)}",
        playlist_id: "some_playlist_id_#{:rand.uniform(1_000_000)}",
        playlist_title: "some playlist name"
      })
    }
  end
end
