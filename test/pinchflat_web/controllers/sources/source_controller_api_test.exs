defmodule PinchflatWeb.Sources.SourceControllerApiTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures
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
          "custom_name" => "Updated Name"
        },
        "_format" => "json"
      }

      conn = put(conn, "/sources/#{source.id}", attrs)

      # Should return 200 for JSON
      assert conn.status == 200

      # Verify the source was updated
      updated_source = Sources.get_source!(source.id)
      assert updated_source.custom_name == "Updated Name"
    end
  end

  describe "delete/2 JSON API" do
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
