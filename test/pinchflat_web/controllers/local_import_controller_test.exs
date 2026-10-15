defmodule PinchflatWeb.LocalImportControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.LocalImport

  test "shows the import workflow and refuses unsigned apply requests", %{conn: conn} do
    source = source_fixture(%{enabled: false})
    html = get(conn, ~p"/sources/#{source}/import_downloads") |> html_response(200)
    assert html =~ "Preview Import"

    assert [_, field_id] =
             Regex.run(~r/<label\b[^>]*for="([^"]+)"[^>]*>\s*Folder relative to downloads\s*<\/label>/, html)

    assert [input] = Regex.run(~r/<input\b[^>]*id="#{Regex.escape(field_id)}"[^>]*>/, html)
    assert input =~ ~s(name="import[directory]")

    assert post(conn, ~p"/sources/#{source}/import_downloads/apply", token: "forged") |> html_response(200) =~
             "could not be applied"
  end

  test "preview tokens are scoped to their source", %{conn: conn} do
    source = source_fixture(%{enabled: false})
    other = source_fixture(%{enabled: false})
    token = Phoenix.Token.sign(PinchflatWeb.Endpoint, "local-import", {to_string(source.id), "", "fingerprint"})

    assert post(conn, ~p"/sources/#{other}/import_downloads/apply", token: token) |> html_response(200) =~
             "does not match this source"

    assert {:error, :pause_source_first} = LocalImport.apply_preview(source_fixture().id, "", "fingerprint")
  end
end
