defmodule Pinchflat.Settings.AppriseServerLive do
  use PinchflatWeb, :live_view

  alias PinchflatWeb.Settings.SettingHTML

  def render(assigns) do
    ~H"""
    <.input
      type="text"
      id="setting_apprise_server"
      name="setting[apprise_server]"
      value={@value}
      label="Apprise Server"
      help={SettingHTML.apprise_server_help()}
      html_help={true}
      inputclass="font-mono text-sm mr-4"
      placeholder="https://discordapp.com/api/webhooks/{WebhookID}/{WebhookToken}"
      phx-change="apprise_server_changed"
    >
      <:input_append>
        <div class="ml-3 mt-2 shrink-0 sm:mt-0">
          <.icon_button
            size="large"
            icon_name={@icon_name}
            phx-click="send_apprise_test"
            tooltip={@tooltip}
            aria-label={@tooltip}
            disabled={blank?(@value)}
          />
        </div>
      </:input_append>
    </.input>
    """
  end

  def mount(_params, session, socket) do
    new_assigns = %{
      value: session["value"],
      icon_name: "hero-paper-airplane",
      tooltip: "Send Test"
    }

    {:ok, assign(socket, new_assigns)}
  end

  def handle_event("send_apprise_test", _params, %{assigns: assigns} = socket) do
    if blank?(assigns.value) do
      {:noreply, socket}
    else
      feedback =
        case backend_runner().run([assigns.value],
               title: "[Pinchflat-ngx] Test Notification",
               body:
                 "Connected 🟢. This is a test message from Pinchflat-ngx. Your notification service is configured properly.",
               notification_type: "success"
             ) do
          {:ok, _} ->
            %{icon_name: "hero-check", tooltip: "Sent!"}

          {:error, _} ->
            %{
              icon_name: "hero-exclamation-triangle",
              tooltip: "Test failed. Check the notification server configuration."
            }
        end

      Process.send_after(self(), :reset_button_icon, 4_000)

      {:noreply, assign(socket, feedback)}
    end
  end

  def handle_event("apprise_server_changed", %{"setting" => setting}, socket) do
    {:noreply, assign(socket, %{value: setting["apprise_server"]})}
  end

  def handle_info(:reset_button_icon, socket) do
    {:noreply, assign(socket, %{icon_name: "hero-paper-airplane", tooltip: "Send Test"})}
  end

  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""

  defp backend_runner do
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
