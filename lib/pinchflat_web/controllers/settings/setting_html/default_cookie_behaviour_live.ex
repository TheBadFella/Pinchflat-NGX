defmodule Pinchflat.Settings.DefaultCookieBehaviourLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.Settings

  @options [
    {"Disabled", "disabled"},
    {"When Needed", "when_needed"},
    {"All Operations", "all_operations"}
  ]

  def render(assigns) do
    ~H"""
    <form phx-submit="save" class="mt-6 border-t border-theme-outline pt-6">
      <.input
        type="select"
        id="setting_default_cookie_behaviour"
        name="default_cookie_behaviour"
        value={@behaviour}
        options={@options}
        label="Default Cookie Behavior for New Sources"
        help="The Cookie Behavior pre-selected when adding a new source. Doesn't change existing sources"
      />

      <div class="mt-4 flex items-center gap-3">
        <.button type="submit" rounding="rounded-m3-sm" class="px-6! py-3!">
          Save
        </.button>
        <span :if={@saved} class="text-sm font-medium text-theme-success">Saved</span>
      </div>
    </form>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, assign_from_settings(socket)}
  end

  def handle_event("save", %{"default_cookie_behaviour" => behaviour}, socket) do
    case Settings.update_setting(Settings.record(), %{default_cookie_behaviour: behaviour}) do
      {:ok, _setting} ->
        Process.send_after(self(), :reset_saved, 4_000)
        {:noreply, socket |> assign_from_settings() |> assign(saved: true)}

      {:error, _changeset} ->
        {:noreply, assign(socket, %{behaviour: behaviour, saved: false})}
    end
  end

  def handle_info(:reset_saved, socket) do
    {:noreply, assign(socket, saved: false)}
  end

  defp assign_from_settings(socket) do
    assign(socket, %{
      behaviour: Settings.record().default_cookie_behaviour || "disabled",
      options: @options,
      saved: false
    })
  end
end
