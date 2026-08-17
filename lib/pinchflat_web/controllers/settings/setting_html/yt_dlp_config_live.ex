defmodule Pinchflat.Settings.YtDlpConfigLive do
  @moduledoc """
  Editor for extras/yt-dlp-configs/base-config.txt, the highest-priority
  user-supplied yt-dlp options applied to every download.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Settings.YtDlpConfigFile

  def render(assigns) do
    ~H"""
    <div>
      <.label>
        Base yt-dlp Config
        <span :if={@present} class="theme-badge-success ml-2 rounded-full px-3 py-1 text-xs font-medium">
          In use
        </span>
        <span
          :if={!@present}
          class="ml-2 rounded-full bg-theme-surface-4 px-3 py-1 text-xs font-medium text-theme-on-surface-muted"
        >
          Empty
        </span>
      </.label>

      <.help>
        Options passed to every download, one per line. Use this for things like <span class="font-mono">--force-ipv4</span>
        or extra retries without restarting the container. Source and media-item
        config files still override this file. See the
        <.inline_link href="https://github.com/yt-dlp/yt-dlp#options">yt-dlp options list</.inline_link>
        for every flag you can put here.
      </.help>

      <div id="yt-dlp-config-form" class="mt-3 space-y-3">
        <div class="theme-field-shell">
          <textarea
            name="contents"
            rows="8"
            phx-change="draft"
            class="theme-input block min-h-[10rem] w-full rounded-m3-sm px-5 py-3 font-mono text-sm focus:ring-0"
            placeholder={placeholder()}
          ><%= Phoenix.HTML.Form.normalize_value("textarea", @contents) %></textarea>
        </div>

        <p :if={@error} class="text-sm theme-status-error">{@error}</p>
        <p :if={@saved} class="text-sm theme-status-success">Config saved. New downloads will pick it up immediately.</p>

        <div class="flex flex-wrap items-center gap-3">
          <.button type="button" rounding="rounded-m3-sm" class="!px-5 !py-3" phx-click="save">
            Save Config
          </.button>

          <button
            :if={@present}
            type="button"
            phx-click="clear"
            data-confirm="Clear the base yt-dlp config?"
            class="theme-danger-button flex items-center gap-2 rounded-m3-sm border px-5 py-3 text-sm"
          >
            <.icon name="hero-trash" class="h-5 w-5" /> Clear
          </button>
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    contents = YtDlpConfigFile.read()

    {:ok,
     assign(socket, %{
       contents: contents,
       present: YtDlpConfigFile.present?(),
       saved: false,
       error: nil
     })}
  end

  def handle_event("draft", %{"contents" => contents}, socket) do
    {:noreply, assign(socket, contents: contents, saved: false, error: nil)}
  end

  def handle_event("save", _params, socket) do
    contents = socket.assigns.contents

    case YtDlpConfigFile.save(contents) do
      :ok ->
        {:noreply,
         assign(socket, %{
           contents: contents,
           present: YtDlpConfigFile.present?(),
           saved: true,
           error: nil
         })}

      {:error, :too_large} ->
        {:noreply,
         assign(socket, error: "Config is too large (max #{YtDlpConfigFile.max_bytes()} bytes)", saved: false)}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Could not save config: #{inspect(reason)}", saved: false)}
    end
  end

  def handle_event("clear", _params, socket) do
    YtDlpConfigFile.clear()

    {:noreply, assign(socket, %{contents: "", present: false, saved: true, error: nil})}
  end

  defp placeholder do
    """
    # One yt-dlp option per line. Examples:
    # --force-ipv4
    # --retries 20
    # --fragment-retries 20
    # --socket-timeout 30
    """
  end
end
