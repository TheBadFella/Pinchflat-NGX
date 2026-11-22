defmodule PinchflatWeb.Api.SourceActionsControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Tasks

  describe "POST /api/sources/:id/actions/download_pending" do
    test "triggers download jobs for pending media", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, "/api/sources/#{source.id}/actions/download_pending")
      response = json_response(conn, 200)

      assert response["message"] == "0 queued, 0 already queued, 0 failed."
    end

    test "returns 404 when source does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, "/api/sources/99999/actions/download_pending")
      end
    end

    test "explains that downloads are disabled instead of reporting a queue count", %{conn: conn} do
      source = source_fixture(download_media: false)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      conn = post(conn, "/api/sources/#{source.id}/actions/download_pending")

      assert json_response(conn, 200)["message"] ==
               "Downloads are disabled for this source. No jobs were queued."

      refute_enqueued(worker: MediaDownloadWorker)
      assert [] = Tasks.list_tasks_for(media_item)
    end

    test "queues pending media when the source allows downloads", %{conn: conn} do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      conn = post(conn, "/api/sources/#{source.id}/actions/download_pending")

      assert json_response(conn, 200)["message"] == "1 queued, 0 already queued, 0 failed."
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
    end

    test "replaces non-executing pending tasks and reports queued items", %{conn: conn} do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      assert {:ok, initial_task} = MediaDownloadWorker.kickoff_with_task(media_item)

      conn = post(conn, "/api/sources/#{source.id}/actions/download_pending")

      assert json_response(conn, 200)["message"] == "1 queued, 0 already queued, 0 failed."
      assert [persisted] = Tasks.list_tasks_for(media_item)
      assert persisted.id != initial_task.id
    end

    test "reports already queued items when pending download task is executing", %{conn: conn} do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil)

      # Oban's uniqueness key includes args, so this executing job must match the
      # retry args to conflict instead of being replaced.
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item, %{"reset_last_error" => true})
      job = Repo.get!(Oban.Job, task.job_id)
      job |> Ecto.Changeset.change(%{state: "executing"}) |> Repo.update!()

      conn = post(conn, "/api/sources/#{source.id}/actions/download_pending")

      assert json_response(conn, 200)["message"] == "0 queued, 1 already queued, 0 failed."
    end

    test "enqueues download job and completes file download from API boundary", %{conn: conn} do
      profile =
        media_profile_fixture(
          download_thumbnail: false,
          download_source_images: false,
          download_metadata: false,
          download_nfo: false,
          output_path_template: "boundary_downloads/{{ title }}.{{ ext }}"
        )

      source = source_fixture(media_profile_id: profile.id, download_media: true)
      media_item = media_item_fixture(source_id: source.id, media_filepath: nil, title: "Boundary Video")

      expected_dir = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "boundary_downloads")
      expected_file = Path.join(expected_dir, "Boundary Video.mp4")

      stub(AppriseRunnerMock, :run, fn _, _ -> {:ok, ""} end)
      stub(UserScriptRunnerMock, :run, fn _, _ -> {:ok, "", 0} end)
      stub(HTTPClientMock, :get, fn _, _, _ -> {:ok, ""} end)

      # One stub with explicit action clauses: Mox matches run/5 by arity, so a
      # separate `expect` would also capture the downloadability precheck.
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, ~s({"is_downloadable": true})}

        _url, :download, opts, _ot, _addl ->
          assert Keyword.fetch!(opts, :output) == Path.join(expected_dir, "%(title)S.%(ext)S")

          File.mkdir_p!(expected_dir)
          File.write!(expected_file, "synthetic boundary download content")

          metadata =
            render_parsed_metadata(:media_metadata)
            |> Map.merge(%{
              "title" => "Boundary Video",
              "ext" => "mp4",
              "filepath" => expected_file,
              "_filename" => expected_file,
              "infojson_filename" => nil,
              "requested_subtitles" => nil,
              "thumbnails" => nil
            })

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      # Boundary trigger
      conn = post(conn, "/api/sources/#{source.id}/actions/download_pending")

      # Assertion (a): Queue acceptance (response and job)
      assert json_response(conn, 200)["message"] == "1 queued, 0 already queued, 0 failed."
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})
      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      # Execute the queued worker
      assert :ok = perform_job(MediaDownloadWorker, job.args)

      # Assertion (b): Completed processing (persisted media_filepath, synthetic file exists)
      reloaded_item = Repo.reload!(media_item)
      assert reloaded_item.media_filepath == expected_file
      assert File.exists?(expected_file)
      assert File.read!(expected_file) == "synthetic boundary download content"

      on_exit(fn ->
        File.rm(expected_file)
        File.rmdir(expected_dir)
      end)
    end
  end

  describe "POST /api/sources/:id/actions/redownload" do
    test "triggers re-download jobs", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, "/api/sources/#{source.id}/actions/redownload")
      response = json_response(conn, 200)

      assert response["message"] == "0 queued, 0 already queued, 0 failed."
    end

    test "returns 404 when source does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, "/api/sources/99999/actions/redownload")
      end
    end
  end

  describe "POST /api/sources/:id/actions/index" do
    test "a real tab failure retries without recording success, then completes indexing and download", %{conn: conn} do
      profile =
        media_profile_fixture(
          output_path_template: "{{ source_custom_name }}/{{ title }}.{{ ext }}",
          download_source_images: false
        )

      source = source_fixture(media_profile_id: profile.id, custom_name: "Index probe")
      expected = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "Index probe/Probe.mp4")

      metadata = %{
        "id" => "index_probe",
        "title" => "Probe",
        "original_url" => "https://www.youtube.com/watch?v=index_probe",
        "live_status" => "not_live",
        "duration" => 600,
        "aspect_ratio" => 1.78,
        "upload_date" => Calendar.strftime(Date.utc_today(), "%Y%m%d"),
        "filename" => expected
      }

      stub(AppriseRunnerMock, :run, fn _, _ -> {:ok, ""} end)

      expect(YtDlpRunnerMock, :run, 3, fn url, :get_media_attributes_for_collection, _, _, _ ->
        cond do
          String.ends_with?(url, "/videos") -> {:ok, Jason.encode!(metadata)}
          String.ends_with?(url, "/shorts") -> {:error, "This channel does not have a shorts tab", 1}
          true -> {:error, "KeyError('INNERTUBE_CONTEXT')", 1}
        end
      end)

      assert conn |> post("/api/sources/#{source.id}/actions/index") |> json_response(200)
      [index_job] = all_enqueued(worker: MediaCollectionIndexingWorker, args: %{"id" => source.id})
      assert %{failure: 1, success: 0} = Oban.drain_queue(queue: :media_collection_indexing, with_scheduled: true)
      assert Repo.reload!(source).last_indexed_at == nil
      assert Repo.reload!(index_job).state == "retryable"
      assert Repo.reload!(index_job).errors != []

      stub(YtDlpRunnerMock, :run, fn
        url, :get_media_attributes_for_collection, _, _, _ ->
          if String.ends_with?(url, "/videos"),
            do: {:ok, Jason.encode!(metadata)},
            else: {:error, "This channel does not have a streams tab", 1}

        _, :get_downloadable_status, _, _, _ ->
          {:ok, "{}"}

        _, :download_thumbnail, _, _, _ ->
          {:ok, ""}

        _, :download, opts, _, _ ->
          assert Keyword.fetch!(opts, :output) == Path.dirname(expected) <> "/%(title)S.%(ext)S"
          File.mkdir_p!(Path.dirname(expected))
          File.write!(expected, "fixture media")

          {:ok,
           Jason.encode!(Map.merge(render_parsed_metadata(:media_metadata), Map.put(metadata, "filepath", expected)))}
      end)

      assert :ok = Oban.retry_job(index_job.id)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :media_collection_indexing, with_scheduled: true)
      assert Repo.reload!(source).last_indexed_at
      item = Repo.get_by!(MediaItem, source_id: source.id, media_id: "index_probe")
      assert item.predicted_media_filepath == expected
      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => item.id})

      stub(UserScriptRunnerMock, :run, fn _, _ -> {:ok, "", 0} end)
      stub(HTTPClientMock, :get, fn _, _, _ -> {:ok, ""} end)
      assert :ok = perform_job(MediaDownloadWorker, %{id: item.id})
      assert Repo.reload!(item).media_filepath == expected
      assert File.read!(expected) == "fixture media"
      on_exit(fn -> File.rm(expected) end)
    end

    test "triggers indexing job", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, "/api/sources/#{source.id}/actions/index")
      response = json_response(conn, 200)

      assert response["message"] == "Index job created"
    end

    test "returns 404 when source does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, "/api/sources/99999/actions/index")
      end
    end
  end

  describe "POST /api/sources/:id/actions/refresh_metadata" do
    test "triggers metadata refresh job", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, "/api/sources/#{source.id}/actions/refresh_metadata")
      response = json_response(conn, 200)

      assert response["message"] == "Metadata refresh job created"
    end

    test "returns 404 when source does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, "/api/sources/99999/actions/refresh_metadata")
      end
    end
  end

  describe "POST /api/sources/:id/actions/sync_files" do
    test "triggers file sync job", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, "/api/sources/#{source.id}/actions/sync_files")
      response = json_response(conn, 200)

      assert response["message"] == "File sync job created"
    end

    test "returns 404 when source does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, "/api/sources/99999/actions/sync_files")
      end
    end
  end
end
