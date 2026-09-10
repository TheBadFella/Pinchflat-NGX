defmodule PinchflatWeb.Api.MediaControllerTest do
  use PinchflatWeb.ConnCase

  import Mox
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import PinchflatWeb.ApiSpecHelper

  describe "GET /api/media" do
    test "returns list of media items", %{conn: conn} do
      item1 = media_item_fixture()
      item2 = media_item_fixture()

      conn = get(conn, "/api/media")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert item1.id in ids
      assert item2.id in ids

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.index")
    end

    test "filters by source_id", %{conn: conn} do
      source1 = source_fixture()
      source2 = source_fixture()
      item1 = media_item_fixture(%{source_id: source1.id})
      _item2 = media_item_fixture(%{source_id: source2.id})

      conn = get(conn, "/api/media?source_id=#{source1.id}")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert ids == [item1.id]

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.index")
    end

    test "respects limit param", %{conn: conn} do
      for _ <- 1..10 do
        media_item_fixture()
      end

      conn = get(conn, "/api/media?limit=5")
      response = json_response(conn, 200)

      assert length(response["data"]) == 5

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.index")
    end
  end

  describe "GET /api/media/:id" do
    test "returns media item details", %{conn: conn} do
      item = media_item_fixture()

      conn = get(conn, "/api/media/#{item.id}")
      response = json_response(conn, 200)

      assert response["id"] == item.id
      assert response["title"] == item.title

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.show")
    end

    test "returns 404 when item does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/media/99999")
      end
    end
  end

  describe "DELETE /api/media/:id" do
    test "deletes media files", %{conn: conn} do
      item = media_item_fixture()

      expect(UserScriptRunnerMock, :run, fn :media_deleted, _data -> {:ok, "", 0} end)

      conn = delete(conn, "/api/media/#{item.id}")
      response = json_response(conn, 200)

      assert response["message"] == "Media files deleted successfully"

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.delete")
    end

    test "deletes with prevent_download=true", %{conn: conn} do
      item = media_item_fixture()

      expect(UserScriptRunnerMock, :run, fn :media_deleted, _data -> {:ok, "", 0} end)

      conn = delete(conn, "/api/media/#{item.id}?prevent_download=true")
      response = json_response(conn, 200)

      assert response["message"]
    end

    test "returns 404 when item does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        delete(conn, "/api/media/99999")
      end
    end
  end

  describe "POST /api/media/:id/actions/download" do
    test "triggers download job", %{conn: conn} do
      item = media_item_fixture()

      conn = post(conn, "/api/media/#{item.id}/actions/download")
      response = json_response(conn, 200)

      assert response["message"] == "Download job created"

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.download")
    end

    test "returns 404 when item does not exist", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, "/api/media/99999/actions/download")
      end
    end
  end

  describe "GET /api/media/recent_downloads" do
    test "returns only downloaded media items", %{conn: conn} do
      downloaded = media_item_fixture(%{media_downloaded_at: DateTime.utc_now()})
      _not_downloaded = media_item_fixture(%{media_downloaded_at: nil})

      conn = get(conn, "/api/media/recent_downloads")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert downloaded.id in ids
      assert length(response["data"]) == 1

      # Validate response matches OpenAPI schema
      assert_response_schema(conn, "Api.MediaController.recent_downloads")
    end

    test "returns items ordered by media_downloaded_at descending", %{conn: conn} do
      older = media_item_fixture(%{media_downloaded_at: ~U[2024-01-01 00:00:00Z]})
      newer = media_item_fixture(%{media_downloaded_at: ~U[2024-06-01 00:00:00Z]})

      conn = get(conn, "/api/media/recent_downloads")
      response = json_response(conn, 200)

      ids = Enum.map(response["data"], & &1["id"])
      assert ids == [newer.id, older.id]
    end

    test "default limit is 50", %{conn: conn} do
      for _ <- 1..55 do
        media_item_fixture(%{media_downloaded_at: DateTime.utc_now()})
      end

      conn = get(conn, "/api/media/recent_downloads")
      response = json_response(conn, 200)

      assert length(response["data"]) == 50
    end

    test "respects custom limit param", %{conn: conn} do
      for _ <- 1..10 do
        media_item_fixture(%{media_downloaded_at: DateTime.utc_now()})
      end

      conn = get(conn, "/api/media/recent_downloads?limit=5")
      response = json_response(conn, 200)

      assert length(response["data"]) == 5
    end

    test "clamps limit to minimum of 1", %{conn: conn} do
      media_item_fixture(%{media_downloaded_at: DateTime.utc_now()})
      media_item_fixture(%{media_downloaded_at: DateTime.utc_now()})

      conn = get(conn, "/api/media/recent_downloads?limit=0")
      response = json_response(conn, 200)

      assert length(response["data"]) == 1
    end

    test "clamps limit to maximum of 500", %{conn: conn} do
      for _ <- 1..5 do
        media_item_fixture(%{media_downloaded_at: DateTime.utc_now()})
      end

      conn = get(conn, "/api/media/recent_downloads?limit=9999")
      response = json_response(conn, 200)

      assert length(response["data"]) == 5
    end

    test "returns expected fields for each item", %{conn: conn} do
      media_item_fixture(%{media_downloaded_at: DateTime.utc_now(), availability: :public})

      conn = get(conn, "/api/media/recent_downloads")
      response = json_response(conn, 200)

      item = hd(response["data"])
      assert Map.has_key?(item, "id")
      assert Map.has_key?(item, "uuid")
      assert Map.has_key?(item, "title")
      assert Map.has_key?(item, "media_id")
      assert item["availability"] == "public"
      assert Map.has_key?(item, "source_id")
      assert Map.has_key?(item, "uploaded_at")
      assert Map.has_key?(item, "media_downloaded_at")
      assert Map.has_key?(item, "media_filepath")
      assert Map.has_key?(item, "thumbnail_filepath")
      assert Map.has_key?(item, "metadata_filepath")
      assert Map.has_key?(item, "nfo_filepath")
      assert Map.has_key?(item, "subtitle_filepaths")
    end

    test "returns empty data when no downloaded items exist", %{conn: conn} do
      _not_downloaded = media_item_fixture(%{media_downloaded_at: nil})

      conn = get(conn, "/api/media/recent_downloads")
      response = json_response(conn, 200)

      assert response["data"] == []
    end
  end
end
