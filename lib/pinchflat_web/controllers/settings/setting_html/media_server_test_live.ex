defmodule Pinchflat.Settings.MediaServerTestLive do
  @moduledoc """
  LiveView button component for testing connectivity to a configured media server.
  """

  use PinchflatWeb, :live_view
  alias Pinchflat.MediaServers

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <button
        type="button"
        id={"test-#{@server_type}-button"}
        phx-click="test_connection"
        class="theme-button theme-outline-button gap-1.5"
        title={@tooltip}
        aria-label={@tooltip}
      >
        <.icon name={@icon_name} class="h-4 w-4 text-theme-primary" />
        <span>{@button_text}</span>
      </button>
      <%= if @status_message do %>
        <span class={"text-xs #{@status_class}"}>
          {@status_message}
        </span>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    server_type = session["server_type"] || "plex"

    socket =
      socket
      |> assign(:server_type, server_type)
      |> assign(:icon_name, "hero-bolt")
      |> assign(:button_text, "Test Connection")
      |> assign(:tooltip, "Test connection using saved settings")
      |> assign(:status_message, nil)
      |> assign(:status_class, "")

    {:ok, socket}
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    server_type = String.to_existing_atom(socket.assigns.server_type)

    case MediaServers.test_connection(server_type) do
      {:ok, :connected} ->
        Process.send_after(self(), :reset_test_button, 4_000)

        {:noreply,
         socket
         |> assign(:icon_name, "hero-check")
         |> assign(:button_text, "Success")
         |> assign(:status_message, "Connected successfully")
         |> assign(:status_class, "theme-badge-success rounded-full px-2 py-0.5")}

      {:error, :missing_configuration} ->
        Process.send_after(self(), :reset_test_button, 4_000)

        {:noreply,
         socket
         |> assign(:icon_name, "hero-exclamation-triangle")
         |> assign(:button_text, "Missing Config")
         |> assign(:status_message, "Save URL & token first")
         |> assign(:status_class, "theme-badge-warning rounded-full px-2 py-0.5")}

      {:error, reason} ->
        Process.send_after(self(), :reset_test_button, 5_000)

        {:noreply,
         socket
         |> assign(:icon_name, "hero-x-mark")
         |> assign(:button_text, "Failed")
         |> assign(:status_message, "#{reason}")
         |> assign(:status_class, "theme-badge-error rounded-full px-2 py-0.5")}
    end
  end

  @impl true
  def handle_info(:reset_test_button, socket) do
    {:noreply,
     socket
     |> assign(:icon_name, "hero-bolt")
     |> assign(:button_text, "Test Connection")
     |> assign(:status_message, nil)
     |> assign(:status_class, "")}
  end
end
