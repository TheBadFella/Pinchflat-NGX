defmodule Pinchflat.AppVersionLive do
  @moduledoc """
  Sidebar card for the running Pinchflat-ngx and yt-dlp versions.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Settings
  alias Pinchflat.AppReleaseCheck

  def render(assigns) do
    ~H"""
    <div class="w-full rounded-m3-sm border border-theme-outline/60 bg-theme-surface-2/70 px-3 py-2 text-xs">
      <div class="flex flex-col gap-1.5">
        <div class="flex min-w-0 flex-nowrap items-center justify-between gap-1.5">
          <.link
            href={app_releases_url(@status)}
            target="_blank"
            class="shrink-0 font-medium text-theme-on-surface transition hover:text-theme-primary"
            title={"Pinchflat-ngx #{@current_version}"}
          >
            Pinchflat-ngx
          </.link>
          <.version_chip
            label={app_chip_label(@status)}
            tooltip={app_chip_tooltip(@status)}
            variant={app_chip_variant(@status)}
          />
        </div>
        <div class="flex min-w-0 flex-nowrap items-center justify-between gap-1.5">
          <.link
            href={ytdlp_releases_url(@policy)}
            target="_blank"
            class="shrink-0 font-medium text-theme-on-surface transition hover:text-theme-primary"
            title={"yt-dlp #{@yt_dlp_version}"}
          >
            yt-dlp
          </.link>
          <.version_chip
            label={ytdlp_chip_label(@policy, @pinned_version)}
            tooltip={ytdlp_chip_tooltip(@policy, @yt_dlp_version)}
          />
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    policy = Settings.get!(:yt_dlp_update_policy)

    {:ok,
     assign(socket, %{
       status: AppReleaseCheck.status(),
       current_version: AppReleaseCheck.display_version(),
       policy: policy,
       pinned_version: Settings.get!(:yt_dlp_pinned_version),
       yt_dlp_version: Settings.get!(:yt_dlp_version) || "unknown"
     })}
  end

  attr :label, :string, required: true
  attr :tooltip, :string, required: true
  attr :variant, :atom, default: :primary

  defp version_chip(assigns) do
    ~H"""
    <span
      class={[
        "group relative inline-flex max-w-full shrink items-center gap-0.5 rounded-full px-1.5 py-0.5",
        "text-center text-[0.6875rem] font-medium leading-none",
        version_chip_color(@variant)
      ]}
      title={@tooltip}
      aria-label={@tooltip}
    >
      <span class="truncate">{@label}</span>
      <span :if={@variant == :warning} aria-hidden="true">!</span>
    </span>
    """
  end

  defp version_chip_color(:warning), do: "theme-badge-warning"
  defp version_chip_color(:dev), do: "theme-badge-dev"
  defp version_chip_color(_), do: "bg-theme-primary text-theme-on-primary"

  defp app_chip_variant({:dev, _sha}), do: :dev
  defp app_chip_variant({:update_available, _, _}), do: :warning
  defp app_chip_variant(_status), do: :primary

  defp app_chip_label({:dev, _sha}), do: "Dev"
  defp app_chip_label({:latest, _current}), do: "Latest"
  defp app_chip_label({:update_available, current, _latest}), do: current

  defp app_chip_tooltip({:dev, sha}) when is_binary(sha) and sha != "" do
    "dev-#{String.slice(sha, 0, 7)}"
  end

  defp app_chip_tooltip({:dev, _sha}), do: "dev"
  defp app_chip_tooltip({:latest, current}), do: current

  defp app_chip_tooltip({:update_available, _current, latest}) do
    "Update available: #{latest}"
  end

  defp app_releases_url({:dev, sha}) when is_binary(sha) and sha != "" do
    "https://github.com/TheBadFella/pinchflat-ngx/commit/#{sha}"
  end

  defp app_releases_url({:dev, _sha}) do
    "https://github.com/TheBadFella/pinchflat-ngx"
  end

  defp app_releases_url(_status) do
    "https://github.com/TheBadFella/pinchflat-ngx/releases"
  end

  defp ytdlp_chip_label("stable", _pinned), do: "Stable"
  defp ytdlp_chip_label("nightly", _pinned), do: "Nightly"
  defp ytdlp_chip_label("nightly_frozen", _pinned), do: "Frozen"
  defp ytdlp_chip_label("nightly_until_stable", _pinned), do: "Until stable"
  defp ytdlp_chip_label("pinned", pinned) when is_binary(pinned) and pinned != "", do: pinned
  defp ytdlp_chip_label("pinned", _pinned), do: "Pinned"
  defp ytdlp_chip_label(_policy, _pinned), do: "Stable"

  defp ytdlp_chip_tooltip(_policy, yt_dlp_version), do: yt_dlp_version

  defp ytdlp_releases_url(policy) when policy in ["nightly", "nightly_frozen", "nightly_until_stable"] do
    "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases"
  end

  defp ytdlp_releases_url(_policy), do: "https://github.com/yt-dlp/yt-dlp/releases"
end
