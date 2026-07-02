defmodule PinchflatWeb.Settings.AppriseServerLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings.AppriseServerLive

  describe "initial rendering" do
    test "renders the input", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, AppriseServerLive, session: create_session(""))

      assert html =~ ~s(input type="text" name="setting[apprise_server]")
    end

    test "sets the initial value from the session", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, AppriseServerLive, session: create_session("cool-value"))

      assert html =~ ~s(value="cool-value")
    end

    test "shows a relevant button icon", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, AppriseServerLive, session: create_session(""))

      assert html =~ "hero-paper-airplane"
      refute html =~ "hero-check"
    end

    test "disables the test button when the input is blank", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, AppriseServerLive, session: create_session(""))

      assert has_element?(view, "button[phx-click=send_apprise_test][disabled]")
    end

    test "enables the test button when the input has a value", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, AppriseServerLive, session: create_session("cool-value"))

      refute has_element?(view, "button[phx-click=send_apprise_test][disabled]")
    end
  end

  describe "when the input is blank" do
    test "does not send a test message", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, AppriseServerLive, session: create_session(""))

      # Push the event directly (bypassing the disabled button) to verify the
      # server-side guard. Mox's verify_on_exit! fails if the runner is called.
      assert render_click(view, "send_apprise_test")
    end
  end

  describe "pressing the button" do
    setup do
      stub(AppriseRunnerMock, :run, fn _, _ -> {:ok, ""} end)

      :ok
    end

    test "sends a test message to the specified server", %{conn: conn} do
      expect(AppriseRunnerMock, :run, fn servers, args ->
        assert servers == ["cool-value"]
        assert args == [title: "Pinchflat Test", body: "This is a test message from Pinchflat"]

        {:ok, ""}
      end)

      {:ok, view, _html} = live_isolated(conn, AppriseServerLive, session: create_session("cool-value"))

      assert view
             |> element("button")
             |> render_click()
    end

    test "sets the button icon to a checkmark", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, AppriseServerLive, session: create_session("cool-value"))

      result =
        view
        |> element("button")
        |> render_click()

      refute result =~ "hero-paper-airplane"
      assert result =~ "hero-check"
    end
  end

  defp create_session(value) do
    %{"value" => value}
  end
end
