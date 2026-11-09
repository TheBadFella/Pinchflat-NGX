defmodule PinchflatWeb.CustomComponents.YtDlpOptionsComponents do
  @moduledoc """
  Shared editor for scoped custom yt-dlp options.

  The textarea is a top-level `yt_dlp_options` parameter so it never enters a
  schema changeset or a public JSON API. Inherited files are shown as presence
  badges only; their contents are never copied into this editor.
  """

  use Phoenix.Component

  attr :id_prefix, :string, required: true
  attr :scope_help, :string, required: true
  attr :contents, :string, default: ""
  attr :version, :any, default: :missing
  attr :present, :boolean, default: false
  attr :readable, :boolean, default: true
  attr :clearable, :boolean, default: false
  attr :inherited, :map, default: %{}
  attr :profile_presence, :map, default: %{}
  attr :error, :string, default: nil

  def yt_dlp_options_editor(assigns) do
    ~H"""
    <section id={"#{@id_prefix}-yt-dlp-options"} class="mt-8">
      <div class="flex flex-wrap items-center gap-3">
        <h4 class="text-base font-semibold text-theme-on-surface">Custom yt-dlp options</h4>
        <span :if={@present} class="theme-badge-success rounded-full px-3 py-1 text-xs font-medium">
          Local options active
        </span>
        <span
          :if={!@present}
          class="rounded-full bg-theme-surface-4 px-3 py-1 text-xs font-medium text-theme-on-surface-muted"
        >
          No local options
        </span>
      </div>

      <p class="mt-2 text-sm leading-6 text-theme-on-surface-muted">
        {@scope_help} One option per line. Changes apply to later download attempts. Blank local options mean no
        additional local options; inherited files still apply. Invalid yt-dlp syntax is saved as text and
        reported by the next download. See the
        <a
          href="https://github.com/yt-dlp/yt-dlp#options"
          target="_blank"
          rel="noopener"
          class="text-theme-primary underline underline-offset-4"
        >
          yt-dlp options list
        </a>
        for flags. <span class="font-mono">--verbose</span>
        is a reasonably safe troubleshooting example.
      </p>

      <div class="mt-3 flex flex-wrap items-center gap-2 text-xs">
        <span class="font-medium text-theme-on-surface-muted">Inherited scopes:</span>
        <span
          :if={@inherited[:base]}
          class="rounded-full bg-theme-primary-container/25 px-2.5 py-1 text-theme-on-primary-container"
        >
          Base config active
        </span>
        <span
          :if={@inherited[:profile]}
          class="rounded-full bg-theme-primary-container/25 px-2.5 py-1 text-theme-on-primary-container"
        >
          Media profile config active
        </span>
        <span
          :if={@inherited[:source]}
          class="rounded-full bg-theme-primary-container/25 px-2.5 py-1 text-theme-on-primary-container"
        >
          Source config active
        </span>
        <span
          :if={map_size(@profile_presence) > 0}
          x-data={"{ profilePresence: #{Jason.encode!(@profile_presence)} }"}
          x-cloak
          x-show="profilePresence[String(mediaProfileId)]"
          class="rounded-full bg-theme-primary-container/25 px-2.5 py-1 text-theme-on-primary-container"
        >
          Selected profile config active
        </span>
        <span
          :if={
            !@inherited[:base] && !@inherited[:profile] && !@inherited[:source] &&
              map_size(@profile_presence) == 0
          }
          class="text-theme-on-surface-muted"
        >
          None active
        </span>
      </div>

      <div :if={@readable} class="theme-field-shell mt-3">
        <textarea
          id={"#{@id_prefix}-yt-dlp-options-textarea"}
          name="yt_dlp_options"
          rows="6"
          class="theme-input block min-h-[10rem] w-full rounded-m3-sm px-5 py-3 font-mono text-sm focus:ring-0"
          placeholder="# One option per line, for example:\n--force-ipv4\n--retries 20"
        ><%= @contents %></textarea>
      </div>

      <div :if={!@readable} class="theme-status-card theme-status-card-warning mt-3 text-sm" role="alert">
        This config file cannot be loaded into the editor. It is preserved and downloads still use it.
        Clear it explicitly to replace it.
      </div>

      <input type="hidden" name="yt_dlp_options_version" value={version_value(@version)} />

      <p :if={@error} class="mt-2 text-sm theme-status-error" role="alert">{@error}</p>

      <div class="mt-3 flex flex-wrap items-center gap-3">
        <button
          :if={@clearable}
          type="submit"
          name="yt_dlp_options_clear"
          value="1"
          data-confirm="Clear only this scope's custom yt-dlp options? Inherited config files can still apply."
          class="theme-button theme-outline-button text-theme-error"
        >
          Clear local options
        </button>
        <span :if={!@clearable && !@present} class="text-xs text-theme-on-surface-muted">
          No local file to clear.
        </span>
      </div>
    </section>
    """
  end

  defp version_value(:missing), do: "missing"
  defp version_value(:any), do: "any"
  defp version_value(version) when is_binary(version), do: version
  defp version_value(_version), do: "any"
end
