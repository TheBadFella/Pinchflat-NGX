defmodule PinchflatWeb.AppLayoutTest do
  use PinchflatWeb.ConnCase

  describe "app layout" do
    test "replaces the header with sidebar search, a phone bar and the palette", %{conn: conn} do
      html = conn |> get(~p"/media_profiles") |> html_response(200)

      refute html =~ "Search all media..."
      refute html =~ ~s(name="q")
      assert html =~ ~s(id="sidebar-search-button")
      assert html =~ ~s(id="phone-bar-search-button")
      assert html =~ ~s(alt="Pinchflat-ngx home")
      assert html =~ ~s(id="command-palette-root")
      refute html =~ "Sign out"
    end
  end

  describe "with OIDC enabled" do
    setup do
      old_oidc = Application.get_env(:pinchflat, :oidc)
      on_exit(fn -> Application.put_env(:pinchflat, :oidc, old_oidc) end)
      Application.put_env(:pinchflat, :oidc, issuer: "https://sso.test", client_id: "fixture", client_secret: "fixture")
    end

    test "shows sign-out in the sidebar as a DELETE link" do
      html =
        build_conn()
        |> init_test_session(%{PinchflatWeb.OIDC.session_key() => %{sub: "fixture"}})
        |> get(~p"/media_profiles")
        |> html_response(200)

      assert html =~ "Sign out"
      assert html =~ ~s(href="/auth/logout")
      assert html =~ ~s(data-method="delete")
    end
  end
end
