defmodule PinchflatWeb.BrowserUserscriptControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Settings

  test "serves the YouTube quick-add userscript without auth", %{conn: conn} do
    Settings.set(external_base_url: "https://pinchflat.example/pf")

    conn = get(conn, "/browser/userscripts/youtube-quick-add-source.user.js")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/javascript"
    body = conn.resp_body
    assert body =~ ~s(const PINCHFLAT_BASE = "https://pinchflat.example/pf")
    assert body =~ "@downloadURL  https://pinchflat.example/pf/browser/userscripts/youtube-quick-add-source.user.js"
    assert body =~ "GM_openInTab"

    manual = File.read!("extras/browser/userscripts/youtube-quick-add-source.user.js")
    [_, hosted_script] = String.split(body, ";(() => {", parts: 2)
    [_, manual_script] = String.split(manual, ";(() => {", parts: 2)

    assert hosted_script ==
             String.replace(manual_script, "'https://pinchflat.example'", ~s("https://pinchflat.example/pf"))

    assert body =~ "// @grant        GM_registerMenuCommand"
  end
end
