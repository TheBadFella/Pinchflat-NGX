defmodule PinchflatWeb.ErrorHTMLTest do
  use PinchflatWeb.ConnCase, async: false

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  test "renders 404.html" do
    assert render_to_string(PinchflatWeb.ErrorHTML, "404", "html", []) =~ "404 (not found)"
  end

  test "renders 500.html" do
    html = render_to_string(PinchflatWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Internal Server Error"
    assert html =~ "https://github.com/TheBadFella/Pinchflat-NGX/issues/new/choose"
    refute html =~ "kieraneglin/pinchflat/issues/new"
  end

  test "renders a 404 through the standalone error layout", %{conn: conn} do
    # The error-rendering conn never runs the browser pipeline (no flash) and
    # may be handling a database failure, so error pages must not render
    # through the app/root layouts (regression: KeyError :flash mid-render).
    conn = get(conn, "/route-that-does-not-exist")

    html = html_response(conn, 404)
    assert html =~ "404 (not found)"
    assert html =~ "<!DOCTYPE html>"
    refute html =~ "Media Profiles"
  end
end
