defmodule Pinchflat.Settings.YtDlpVersionLive do
  use PinchflatWeb, :live_view

  alias PinchflatWeb.Settings.SettingHTML
  alias Pinchflat.YtDlp.ReleaseLookup

  @policy_options [
    {"Stable (recommended)", "stable"},
    {"Nightly, auto-updated", "nightly"},
    {"Nightly, frozen", "nightly_frozen"},
    {"Nightly until stable catches up", "nightly_until_stable"},
    {"Pin a specific version", "pinned"}
  ]

  def render(assigns) do
    ~H"""
    <div>
      <.input
        type="select"
        id="setting_yt_dlp_update_policy"
        name="setting[yt_dlp_update_policy]"
        value={@policy}
        options={@policy_options}
        label="Update Behavior"
        help={SettingHTML.yt_dlp_update_policy_help()}
        phx-change="policy_changed"
      />

      <.input
        :if={@policy == "pinned"}
        type="text"
        id="setting_yt_dlp_pinned_version"
        name="setting[yt_dlp_pinned_version]"
        value={@pinned_version}
        label="Pinned Version"
        help={SettingHTML.yt_dlp_pinned_version_help()}
        html_help={true}
        inputclass="font-mono text-sm mr-4"
        placeholder="2025.12.08"
        phx-change="pinned_version_changed"
      >
        <:input_append>
          <.icon_button
            icon_name={@icon_name}
            class="h-12 w-12 disabled:opacity-50 disabled:cursor-not-allowed"
            phx-click="check_version"
            tooltip={@tooltip}
            disabled={blank?(@pinned_version)}
          />
        </:input_append>
      </.input>
    </div>
    """
  end

  def mount(_params, session, socket) do
    new_assigns = %{
      policy: session["policy"] || "stable",
      pinned_version: session["pinned_version"],
      policy_options: @policy_options,
      icon_name: "hero-beaker",
      tooltip: "Check availability"
    }

    {:ok, assign(socket, new_assigns)}
  end

  def handle_event("policy_changed", %{"setting" => setting}, socket) do
    {:noreply, assign(socket, %{policy: setting["yt_dlp_update_policy"]})}
  end

  def handle_event("pinned_version_changed", %{"setting" => setting}, socket) do
    {:noreply, assign(socket, %{pinned_version: setting["yt_dlp_pinned_version"]})}
  end

  def handle_event("check_version", _params, %{assigns: assigns} = socket) do
    if blank?(assigns.pinned_version) do
      {:noreply, socket}
    else
      Process.send_after(self(), :reset_button_icon, 4_000)

      assigns =
        if ReleaseLookup.version_available?(String.trim(assigns.pinned_version)) do
          %{icon_name: "hero-check", tooltip: "Version available"}
        else
          %{icon_name: "hero-x-mark", tooltip: "Version not found"}
        end

      {:noreply, assign(socket, assigns)}
    end
  end

  def handle_info(:reset_button_icon, socket) do
    {:noreply, assign(socket, %{icon_name: "hero-beaker", tooltip: "Check availability"})}
  end

  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""
end
