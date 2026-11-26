defmodule PinchflatWeb.Layouts.HomeLinkTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Settings

  @logo_link ~r{<a href="/"[^>]*>\s*<img src="/images/(logo|icon)-2024-03-20[^"]*" alt="Pinchflat-ngx home"}

  test "app pages link the phone bar logo and the sidebar logo to home", %{conn: conn} do
    Settings.set(onboarding: false)

    html = conn |> get(~p"/sources") |> html_response(200)

    assert Regex.scan(@logo_link, html) |> length() >= 1
    assert html =~ ~r{<a href="/"[^>]*theme-sidebar-brand-link}
    assert html =~ ~r{<img src="/images/logo-2024-03-20[^"]*" alt="Pinchflat-ngx home" class="theme-phone-bar-logo"}
    refute html =~ "theme-sidebar-header-brand"
  end

  test "the onboarding layout links its logo to home", %{conn: conn} do
    html = conn |> get(~p"/?onboarding=1") |> html_response(200)

    assert html =~ @logo_link
  end
end
