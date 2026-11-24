defmodule PinchflatWeb.Sources.SourceControllerApiTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures
  import Pinchflat.MediaFixtures
  import Mox

  alias Pinchflat.Sources

  setup :verify_on_exit!

  describe "index/2 JSON API" do
    test "returns list of sources as JSON", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, "/sources", _format: "json")

      response = json_response(conn, 200)
      assert is_list(response["data"])
      refute response["data"] == []
      assert List.first(response["data"])["id"] == source.id
    end
  end

  describe "show/2 JSON API" do
    test "returns source details as JSON", %{conn: conn} do
      source = source_fixture() |> Repo.preload(:media_profile)

      conn = get(conn, "/sources/#{source.id}", _format: "json")

      response = json_response(conn, 200)
      assert response["id"] == source.id
      assert response["uuid"] == source.uuid
      assert response["custom_name"] == source.custom_name
      assert response["custom_name_locked"] == false
      assert response["description_locked"] == false
    end

    test "returns 404 for non-existent source", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/sources/999999", _format: "json")
      end
    end
  end

  describe "create/2 JSON API" do
    test "creates source and returns JSON", %{conn: conn} do
      media_profile = media_profile_fixture()

      # Mock the YtDlpRunner to avoid external API calls
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Test Channel",
           channel_id: "UC_test_channel_id",
           playlist_id: "UC_test_channel_id",
           playlist_title: "Test Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UCxxxxxxxxxxxx",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Test Channel"
        },
        "_format" => "json"
      }

      conn = post(conn, "/sources", attrs)

      # Should return 201 Created for successful JSON creation
      assert conn.status == 201
    end
  end

  describe "update/2 JSON API" do
    test "updates source and returns JSON", %{conn: conn} do
      source = source_fixture()

      attrs = %{
        "source" => %{
          "custom_name" => "Updated Name",
          "description" => "Updated description",
          "custom_name_locked" => "true",
          "description_locked" => "true"
        },
        "_format" => "json"
      }

      conn = put(conn, "/sources/#{source.id}", attrs)

      # Should return 200 for JSON
      assert conn.status == 200

      # Verify the source was updated
      updated_source = Sources.get_source!(source.id)
      assert updated_source.custom_name == "Updated Name"
      assert updated_source.description == "Updated description"
      assert updated_source.custom_name_locked
      assert updated_source.description_locked
    end
  end

  describe "title language over JSON API" do
    test "creates a source with a title language and round-trips it", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Language Channel",
           channel_id: "UC_language_channel",
           playlist_id: "UC_language_channel",
           playlist_title: "Language Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_language_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Language Channel",
          "title_language" => "en"
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["title_language"] == "en"

      source_id = response["id"]
      get_response = conn |> recycle() |> get("/sources/#{source_id}?_format=json") |> json_response(200)
      assert get_response["title_language"] == "en"
    end

    test "updates a source title language and round-trips it", %{conn: conn} do
      source = source_fixture()

      attrs = %{"source" => %{"title_language" => "ja"}, "_format" => "json"}

      response = conn |> put("/sources/#{source.id}", attrs) |> json_response(200)
      assert response["title_language"] == "ja"

      assert Sources.get_source!(source.id).title_language == "ja"

      show = conn |> recycle() |> get("/sources/#{source.id}?_format=json") |> json_response(200)
      assert show["title_language"] == "ja"
    end

    test "returns a validation error for an invalid title language", %{conn: conn} do
      source = source_fixture()

      response =
        conn
        |> put("/sources/#{source.id}", %{"source" => %{"title_language" => "nope!"}, "_format" => "json"})
        |> json_response(422)

      assert response["errors"]["title_language"] == ["must be a YouTube language code such as en, ja, pt-PT or zh-CN"]
      assert Sources.get_source!(source.id).title_language == nil
    end
  end

  describe "keep newest over JSON API" do
    test "creates a source with a keep_newest_count and round-trips it", %{conn: conn} do
      media_profile = media_profile_fixture()

      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok,
         Phoenix.json_library().encode!(%{
           channel: "Keep Newest Channel",
           channel_id: "UC_keep_newest_channel",
           playlist_id: "UC_keep_newest_channel",
           playlist_title: "Keep Newest Channel - videos"
         })}
      end)

      attrs = %{
        "source" => %{
          "original_url" => "https://www.youtube.com/channel/UC_keep_newest_channel",
          "media_profile_id" => media_profile.id,
          "custom_name" => "Keep Newest Channel",
          "keep_newest_count" => 4
        },
        "_format" => "json"
      }

      response = conn |> post("/sources", attrs) |> json_response(201)
      assert response["keep_newest_count"] == 4

      show = conn |> recycle() |> get("/sources/#{response["id"]}?_format=json") |> json_response(200)
      assert show["keep_newest_count"] == 4
    end

    test "updates a keep_newest_count without the HTML confirmation", %{conn: conn} do
      source = source_fixture(%{keep_newest_count: 5, download_media: false})

      for offset <- 0..4 do
        media_item_fixture(%{
          source_id: source.id,
          media_filepath: "/video/#{offset}.mp4",
          uploaded_at: DateTime.add(~U[2026-11-20 00:00:00Z], offset, :day)
        })
      end

      attrs = %{"source" => %{"keep_newest_count" => 2}, "_format" => "json"}

      response = conn |> put("/sources/#{source.id}", attrs) |> json_response(200)
      assert response["keep_newest_count"] == 2

      assert Sources.get_source!(source.id).keep_newest_count == 2
    end
  end

  describe "delete/2 JSON API" do
    test "a protected source returns JSON conflict without scheduling deletion", %{conn: conn} do
      profile = media_profile_fixture() |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
      source = source_fixture(media_profile_id: profile.id)
      path = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "blocked-#{Ecto.UUID.generate()}.mp4")
      File.write!(path, "original")
      item = media_item_fixture(source_id: source.id, media_filepath: path)
      {:ok, _watch} = Pinchflat.MediaWatch.enroll_on_first_completion(item, Repo.preload(source, :media_profile))

      for delete_files <- ["false", "true"] do
        response = delete(conn, "/sources/#{source.id}?delete_files=#{delete_files}&_format=json")
        assert json_response(response, 409)["error"] =~ "End watch protection"
        refute Repo.reload!(source).marked_for_deletion_at
        refute_enqueued(worker: Pinchflat.Sources.SourceDeletionWorker)
      end
    end

    test "deletes source and returns JSON", %{conn: conn} do
      source = source_fixture()

      conn = delete(conn, "/sources/#{source.id}?delete_files=false&_format=json")

      # Should return 200 for JSON
      assert conn.status == 200

      # Verify source is marked for deletion
      updated_source = Sources.get_source!(source.id)
      assert updated_source.marked_for_deletion_at != nil
    end
  end
end
