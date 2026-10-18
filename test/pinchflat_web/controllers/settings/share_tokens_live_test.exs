defmodule Pinchflat.Settings.ShareTokensLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.ShareTokens

  setup do
    profile = media_profile_fixture()
    %{profile: profile}
  end

  describe "ShareTokensLive" do
    test "creates a token with the chosen expiry", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live_isolated(conn, Pinchflat.Settings.ShareTokensLive)

      view
      |> form("#create-share-token-form", %{
        "name" => "Owned expiring shortcut",
        "media_profile_id" => to_string(profile.id),
        "expiry_days" => "30"
      })
      |> render_submit()

      [token] = ShareTokens.list_tokens()
      assert DateTime.diff(token.expires_at, token.inserted_at, :second) == 2_592_000
      assert has_element?(view, "#raw-token-secret-input")
    end

    test "bookmarklet uses the browser origin and deployment prefix", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, Pinchflat.Settings.ShareTokensLive, session: %{"base_url" => "https://owned.example/pf/"})

      assert has_element?(view, "#intake-bookmarklet-link[href*='https://owned.example/pf/browse?url=']")
    end

    test "renders empty token state and bookmarklet link", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, Pinchflat.Settings.ShareTokensLive)

      assert html =~ "Scoped Share Tokens"
      assert html =~ "No share tokens created yet"
      assert has_element?(view, "#intake-bookmarklet-link")
      assert html =~ "javascript:(function()"
    end

    test "creates a new share token and reveals raw secret once", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live_isolated(conn, Pinchflat.Settings.ShareTokensLive)

      html =
        view
        |> form("form[phx-submit='create_token']", %{
          "name" => "Mobile Safari Shortcut",
          "media_profile_id" => to_string(profile.id)
        })
        |> render_submit()

      assert html =~ "New Share Token Created: Mobile Safari Shortcut"
      assert html =~ "Copy this token now. For security, it will not be displayed again."
      assert has_element?(view, "#raw-token-secret-input")

      # Token row is now listed in the table
      assert html =~ "Mobile Safari Shortcut"
      assert html =~ "Active"

      # Dismissing secret removes banner
      html_after_dismiss =
        view
        |> element("button", "Dismiss")
        |> render_click()

      refute html_after_dismiss =~ "New Share Token Created"
      refute has_element?(view, "#raw-token-secret-input")
    end

    test "revoking a token updates its status", %{conn: conn, profile: profile} do
      {:ok, token, _secret} = ShareTokens.create_token(%{name: "Revocable Token", media_profile_id: profile.id})

      {:ok, view, _html} = live_isolated(conn, Pinchflat.Settings.ShareTokensLive)

      assert has_element?(view, "#token-row-#{token.id}", "Active")

      html =
        view
        |> element("button[phx-click='revoke_token'][phx-value-id='#{token.id}']")
        |> render_click()

      assert html =~ "Revoked"
      refute has_element?(view, "button[phx-click='revoke_token'][phx-value-id='#{token.id}']")
    end

    test "deleting a token removes it completely", %{conn: conn, profile: profile} do
      {:ok, token, _secret} = ShareTokens.create_token(%{name: "Deletable Token", media_profile_id: profile.id})

      {:ok, view, _html} = live_isolated(conn, Pinchflat.Settings.ShareTokensLive)

      assert has_element?(view, "#token-row-#{token.id}")

      view
      |> element("button[phx-click='delete_token'][phx-value-id='#{token.id}']")
      |> render_click()

      refute has_element?(view, "#token-row-#{token.id}")
      assert_raise Ecto.NoResultsError, fn -> ShareTokens.get_token!(token.id) end
    end
  end
end
