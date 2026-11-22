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

    test "documents translated title fields", %{conn: conn} do
      response = conn |> get("/api/spec") |> json_response(200)
      schemas = response["components"]["schemas"]

      assert schemas["Source"]["properties"]["title_language"]["type"] == "string"
      assert schemas["Source"]["properties"]["title_language"]["nullable"] == true
      assert schemas["Source"]["properties"]["title_language"]["description"] == "Language code for translated titles"

      for schema_name <- ["CreateSourceRequest", "UpdateSourceRequest"] do
        title_language = schemas[schema_name]["properties"]["source"]["properties"]["title_language"]

        assert title_language["type"] == "string"
        assert title_language["nullable"] == true
        assert title_language["description"] == "Language code for translated titles"
        assert title_language["example"] == "en"
      end

      translated_title = schemas["MediaItem"]["properties"]["translated_title"]
      assert translated_title["type"] == "string"
      assert translated_title["nullable"] == true
      assert translated_title["description"] == "Channel-provided translated title"
      assert translated_title["example"] == "My Translated Title"
    end

    test "routes reference the updated source and media schemas", %{conn: conn} do
      response = conn |> get("/api/spec") |> json_response(200)

      create_ref =
        response["paths"]["/sources"]["post"]["requestBody"]["content"]["application/json"]["schema"]["$ref"]

      update_ref =
        response["paths"]["/sources/{id}"]["put"]["requestBody"]["content"]["application/json"]["schema"]["$ref"]

      show_ref =
        response["paths"]["/api/media/{id}"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      assert create_ref == "#/components/schemas/CreateSourceRequest"
      assert update_ref == "#/components/schemas/UpdateSourceRequest"
      assert show_ref["$ref"] == "#/components/schemas/MediaItem"
      assert response["paths"]["/api/media/{id}"]["get"]["summary"] == "Get media item"
    end
  end
end
