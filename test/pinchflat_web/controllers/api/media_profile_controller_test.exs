defmodule PinchflatWeb.Api.MediaProfileControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.ProfilesFixtures
  import PinchflatWeb.ApiSpecHelper

  alias Pinchflat.Profiles

  describe "GET /api/media_profiles" do
    test "returns list of media profiles", %{conn: conn} do
      profile1 = media_profile_fixture(%{name: "Profile 1"})
      profile2 = media_profile_fixture(%{name: "Profile 2"})

      conn = get(conn, "/api/media_profiles")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert profile1.id in ids
      assert profile2.id in ids
      assert length(response["data"]) == 2

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaProfileController.index")
    end

    test "returns empty list when no profiles exist", %{conn: conn} do
      conn = get(conn, "/api/media_profiles")
      response = json_response(conn, 200)

      assert response["data"] == []
    end
  end

  describe "GET /api/media_profiles/:id" do
    test "returns media profile details", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Test Profile"})

      conn = get(conn, "/api/media_profiles/#{profile.id}")
      response = json_response(conn, 200)

      assert response["id"] == profile.id
      assert response["name"] == "Test Profile"

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaProfileController.show")
    end

    test "returns 404 when profile does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/media_profiles/99999")
      end
    end
  end

  describe "POST /api/media_profiles" do
    test "creates media profile with valid params", %{conn: conn} do
      params = %{
        media_profile: %{
          name: "New Profile",
          output_path_template: "/downloads/{{ title }}.{{ ext }}"
        }
      }

      conn = post(conn, "/api/media_profiles", params)
      response = json_response(conn, 201)

      assert response["name"] == "New Profile"
      assert response["output_path_template"] == "/downloads/{{ title }}.{{ ext }}"
      assert response["id"]

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaProfileController.create", 201)
    end

    test "returns 422 with invalid params", %{conn: conn} do
      params = %{
        media_profile: %{
          name: ""
        }
      }

      conn = post(conn, "/api/media_profiles", params)
      response = json_response(conn, 422)

      assert response["errors"]
    end
  end

  describe "PUT /api/media_profiles/:id" do
    test "updates media profile with valid params", %{conn: conn} do
      profile = media_profile_fixture(%{name: "Old Name"})

      params = %{
        media_profile: %{
          name: "New Name"
        }
      }

      conn = put(conn, "/api/media_profiles/#{profile.id}", params)
      response = json_response(conn, 200)

      assert response["name"] == "New Name"
      assert response["id"] == profile.id

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaProfileController.update")
    end

    test "returns 404 when profile does not exist", %{conn: conn} do
      params = %{media_profile: %{name: "New Name"}}

      assert_error_sent 404, fn ->
        put(conn, "/api/media_profiles/99999", params)
      end
    end

    test "accepts a positive watch window now that guarded replacements are approved", %{conn: conn} do
      profile = media_profile_fixture()
      conn = put(conn, "/api/media_profiles/#{profile.id}", %{media_profile: %{watch_window_days: 7}})
      response = json_response(conn, 200)

      assert response["watch_window_days"] == 7
      assert Profiles.get_media_profile!(profile.id).watch_window_days == 7
      assert_response_schema(conn, "Api.MediaProfileController.update")
    end

    test "rejects a watch window outside 0..365", %{conn: conn} do
      profile = media_profile_fixture()
      conn = put(conn, "/api/media_profiles/#{profile.id}", %{media_profile: %{watch_window_days: 366}})

      assert json_response(conn, 422)["errors"]["watch_window_days"]
      assert Profiles.get_media_profile!(profile.id).watch_window_days == 0
    end

    test "returns 422 with invalid params", %{conn: conn} do
      profile = media_profile_fixture()

      params = %{
        media_profile: %{
          name: ""
        }
      }

      conn = put(conn, "/api/media_profiles/#{profile.id}", params)
      response = json_response(conn, 422)

      assert response["errors"]
    end
  end

  describe "DELETE /api/media_profiles/:id" do
    test "deletes media profile", %{conn: conn} do
      profile = media_profile_fixture()

      conn = delete(conn, "/api/media_profiles/#{profile.id}")
      response = json_response(conn, 200)

      assert response["message"] == "Media profile deletion started"
      refute Profiles.list_media_profiles() |> Enum.any?(&(&1.id == profile.id))
    end

    test "deletes with delete_files=true", %{conn: conn} do
      profile = media_profile_fixture()

      conn = delete(conn, "/api/media_profiles/#{profile.id}?delete_files=true")
      response = json_response(conn, 200)

      assert response["message"]
    end

    test "returns 404 when profile does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        delete(conn, "/api/media_profiles/99999")
      end
    end
  end
end
