defmodule PinchflatWeb.Api.SourceActionsControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

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
