defmodule PinchflatWeb.ApiSpecControllerTest do
  use PinchflatWeb.ConnCase

  describe "spec/2" do
    test "returns OpenAPI spec JSON", %{conn: conn} do
      conn = get(conn, "/api/spec")

      response = json_response(conn, 200)

      assert response["info"]["title"] == "Pinchflat-ngx API"
      assert response["info"]["version"] == "1.0.0"
      assert response["paths"]["/healthcheck"]["get"]["summary"] == "Health check"
      assert response["paths"]["/api/media/recent_downloads"]["get"]["summary"] == "Recent downloads"
      assert response["paths"]["/sources"]["get"]["summary"] == "List sources"
      assert response["paths"]["/sources"]["post"]["summary"] == "Create source"
      assert response["paths"]["/sources/{id}"]["get"]["summary"] == "Get source"
      assert response["paths"]["/sources/{id}"]["put"]["summary"] == "Update source"
      assert response["paths"]["/sources/{id}"]["delete"]["summary"] == "Delete source"
    end
  end
end
