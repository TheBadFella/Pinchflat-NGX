defmodule PinchflatWeb.ApiDocsControllerTest do
  use PinchflatWeb.ConnCase

  describe "index/2" do
    test "returns Scalar UI HTML page", %{conn: conn} do
      conn = get(conn, "/api/docs")

      assert html = html_response(conn, 200)
      assert html =~ "Pinchflat-ngx API Documentation"
      assert html =~ "@scalar/api-reference@1.83.0"
      assert html =~ "integrity=\"sha384-Z2Wz4L/5mCSEGTCpHPw3JIN6+eRxpIwq2sE2QfGtP+hmmwcgJKNVK9zBbfnbjlKN\""
      assert html =~ "data-configuration='{\"proxyUrl\":\"\"}'"
      assert html =~ "/api/spec"
    end

    test "respects non-root base_route_path configuration", %{conn: conn} do
      original_path = Application.get_env(:pinchflat, :base_route_path)
      Application.put_env(:pinchflat, :base_route_path, "/custom_prefix")

      on_exit(fn ->
        Application.put_env(:pinchflat, :base_route_path, original_path)
      end)

      conn = get(conn, "/api/docs")
      assert html_response(conn, 200) =~ "/custom_prefix/api/spec"
      assert PinchflatWeb.ApiSpec.spec().servers |> hd() |> Map.fetch!(:url) == "/custom_prefix"
    end
  end
end
