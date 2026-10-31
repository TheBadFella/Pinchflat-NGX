defmodule Pinchflat.Settings.YtDlpPluginsLive do
  @moduledoc """
  Manages yt-dlp plugin packages from Settings.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.HTTP.SafeFetch
  alias Pinchflat.YtDlp.PluginDirectory

  def render(assigns) do
    ~H"""
    <div>
      <.label>
        yt-dlp Plugins <span class={plugin_count_class(@plugins)}>{plugin_count(@plugins)}</span>
      </.label>

      <.help>
        Plugins add extractors or postprocessors to yt-dlp. Install a direct archive URL,
        or drop a package into <span class="font-mono">/config/extras/yt-dlp-plugins</span>.
        Postprocessor plugins also need <span class="font-mono">--use-postprocessor NAME</span> in the base yt-dlp config.
      </.help>

      <div class="theme-status-card theme-status-card-warning mt-4 text-xs">
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="h-5 w-5 shrink-0 text-theme-warning" />
          <div>
            <p class="font-bold">Plugins run arbitrary Python code.</p>
            <p class="mt-1">
              Only install plugins you trust. Extractor plugins take priority over built-in
              extractors and can break Pinchflat-ngx or change downloaded content.
            </p>
          </div>
        </div>
      </div>

      <form
        id="plugin-upload-form"
        phx-submit="upload_plugin"
        phx-change="validate_upload"
        class="mt-4 flex flex-wrap items-center gap-3"
      >
        <label
          phx-drop-target={@uploads.plugin.ref}
          class="theme-button theme-button-secondary cursor-pointer gap-2 focus-within:ring-2 focus-within:ring-theme-primary/70"
        >
          <.icon name="hero-arrow-up-tray" class="h-5 w-5" />
          <span>{upload_label(@uploads.plugin.entries)}</span>
          <.live_file_input
            upload={@uploads.plugin}
            accept=".zip,.whl,.egg"
            class="sr-only"
          />
        </label>

        <.button :if={@uploads.plugin.entries != []} type="submit" variant="primary">
          Save Plugin
        </.button>
      </form>

      <.error :for={err <- upload_errors(@uploads.plugin)}>{error_to_string(err)}</.error>

      <form
        id="plugin-url-form"
        phx-submit="install_from_url"
        class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end"
      >
        <div class="flex-1">
          <.input
            type="text"
            name="url"
            value={@url}
            label="Plugin Archive URL"
            placeholder="https://github.com/owner/repo/releases/latest/download/plugin.zip"
            help={url_help(@allowed_hosts)}
            inputclass="font-mono text-sm"
          />
        </div>
        <.button type="submit" variant="secondary" phx-disable-with="Installing...">
          Install from URL
        </.button>
      </form>

      <p :if={@notice} class="mt-3 text-sm theme-status-success">{@notice}</p>
      <p :if={@error} class="mt-3 text-sm theme-status-error">{@error}</p>

      <div class="mt-6 border-t border-theme-outline/60 pt-5">
        <h4 class="text-base font-semibold text-theme-on-surface">Installed Plugins</h4>

        <p :if={@plugins == []} class="mt-3 text-sm text-theme-on-surface-muted">
          No plugins installed. Upload an archive or add one to <span class="font-mono">/config/extras/yt-dlp-plugins</span>.
        </p>

        <ul :if={@plugins != []} class="mt-3 divide-y divide-theme-outline/40">
          <li
            :for={plugin <- @plugins}
            id={"plugin-#{plugin.filename}"}
            class="flex flex-col gap-3 py-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="min-w-0">
              <p class="truncate font-medium text-theme-on-surface">{plugin.name}</p>
              <p class="text-xs text-theme-on-surface-muted">
                {plugin_kind(plugin)}
                <span :if={plugin.size}>· <.readable_filesize byte_size={plugin.size} /></span>
                <span :if={plugin.source_url}>· {plugin.source_url}</span>
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <.button
                :if={plugin.source_url}
                type="button"
                phx-click="update_plugin"
                phx-value-filename={plugin.filename}
                variant="secondary"
                size="compact"
                data-confirm="Replace this plugin with the latest archive from its source URL?"
              >
                Update
              </.button>

              <.button
                type="button"
                phx-click="remove_plugin"
                phx-value-filename={plugin.filename}
                variant="danger"
                size="compact"
                data-confirm="Remove this plugin?"
              >
                Remove
              </.button>
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:plugins, PluginDirectory.list())
      |> assign(:url, "")
      |> assign(:notice, nil)
      |> assign(:error, nil)
      |> assign(:allowed_hosts, SafeFetch.allowed_hosts())
      |> allow_upload(:plugin,
        accept: :any,
        max_entries: 1,
        max_file_size: PluginDirectory.max_bytes()
      )

    {:ok, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("upload_plugin", _params, socket) do
    results =
      consume_uploaded_entries(socket, :plugin, fn %{path: path}, entry ->
        {:ok, PluginDirectory.install_archive(path, filename: entry.client_name)}
      end)

    case results do
      [{:ok, _entry}] ->
        {:noreply,
         socket
         |> assign(:plugins, PluginDirectory.list())
         |> assign(:notice, "Plugin installed.")
         |> assign(:error, nil)}

      [{:error, reason}] ->
        {:noreply, assign(socket, :error, humanize_error(reason))}

      [] ->
        {:noreply, assign(socket, :error, "Choose a plugin archive to upload.")}
    end
  end

  def handle_event("install_from_url", %{"url" => url}, socket) do
    url = String.trim(url)

    if url == "" do
      {:noreply, assign(socket, :error, "Enter a plugin archive URL.")}
    else
      case PluginDirectory.install_from_url(url) do
        {:ok, _entry} ->
          {:noreply,
           socket
           |> assign(:plugins, PluginDirectory.list())
           |> assign(:url, url)
           |> assign(:notice, "Plugin installed from URL.")
           |> assign(:error, nil)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:url, url)
           |> assign(:notice, nil)
           |> assign(:error, humanize_error(reason))}
      end
    end
  end

  def handle_event("update_plugin", %{"filename" => filename}, socket) do
    case PluginDirectory.update_from_source(filename) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:plugins, PluginDirectory.list())
         |> assign(:notice, "Plugin updated.")
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, humanize_error(reason))}
    end
  end

  def handle_event("remove_plugin", %{"filename" => filename}, socket) do
    case PluginDirectory.remove(filename) do
      :ok ->
        {:noreply,
         socket
         |> assign(:plugins, PluginDirectory.list())
         |> assign(:notice, "Plugin removed.")
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, humanize_error(reason))}
    end
  end

  defp plugin_count([]), do: "None"
  defp plugin_count(plugins), do: "#{length(plugins)} installed"

  defp plugin_count_class([]) do
    "ml-2 rounded-full bg-theme-surface-4 px-3 py-1 text-xs font-medium text-theme-on-surface-muted"
  end

  defp plugin_count_class(_plugins) do
    "theme-badge-success ml-2 rounded-full px-3 py-1 text-xs font-medium"
  end

  defp plugin_kind(%{kind: :directory}), do: "Folder"
  defp plugin_kind(%{kind: :archive}), do: "Archive"

  defp url_help(allowed_hosts) do
    "Direct .zip, .whl, or .egg archive URL. Allowed hosts: #{Enum.join(allowed_hosts, ", ")}. " <>
      "Add hosts with YT_DLP_PLUGIN_URL_ALLOWLIST."
  end

  defp upload_label([]), do: "Choose a plugin archive"
  defp upload_label([entry | _]), do: entry.client_name

  defp error_to_string(:too_large), do: "File is too large (max 25 MB)"
  defp error_to_string(:not_accepted), do: "Only .zip, .whl, and .egg files are accepted"
  defp error_to_string(:too_many_files), do: "Only one file can be uploaded"
  defp error_to_string(_), do: "Invalid file"

  defp humanize_error(:unsupported_extension), do: "Only .zip, .whl, and .egg plugin archives are supported."

  defp humanize_error(:invalid_archive), do: "The file is not a valid plugin archive."

  defp humanize_error(:missing_plugin_namespace),
    do: "The archive does not contain yt_dlp_plugins/ at its root."

  defp humanize_error(:wrapper_directory),
    do: "The archive contains a wrapper directory. Repackage it with yt_dlp_plugins/ at the root."

  defp humanize_error(:unsafe_archive), do: "The archive contains an unsafe file path."
  defp humanize_error(:too_large), do: "The plugin archive is too large (max 25 MB)."

  defp humanize_error(:already_installed),
    do: "A plugin with that filename is already installed. Remove it first."

  defp humanize_error(:invalid_name), do: "The plugin filename is invalid."
  defp humanize_error(:not_found), do: "The plugin could not be found."
  defp humanize_error(:no_source_url), do: "This plugin was not installed from a URL."
  defp humanize_error(:invalid_url), do: "Enter a valid HTTP or HTTPS archive URL."
  defp humanize_error(:host_not_allowed), do: "That host is not allowed. Add it to YT_DLP_PLUGIN_URL_ALLOWLIST."
  defp humanize_error(:unsafe_url), do: "That URL resolves to a private or reserved address."
  defp humanize_error(:unresolvable_host), do: "That host could not be resolved."
  defp humanize_error(:too_many_redirects), do: "The URL redirected too many times."
  defp humanize_error(:invalid_redirect), do: "The URL returned an invalid redirect."
  defp humanize_error({:http_status, status}), do: "The server returned HTTP #{status}."
  defp humanize_error(:file_error), do: "The plugin file could not be written."
  defp humanize_error(_reason), do: "The plugin operation failed."
end
