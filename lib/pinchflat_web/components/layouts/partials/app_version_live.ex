defmodule Pinchflat.AppVersionLive do
  @moduledoc """
  Sidebar card for the running PinchYT and yt-dlp versions.
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
            href="https://github.com/TheBadFella/PinchYT/releases"
            target="_blank"
            class="shrink-0 font-medium text-theme-on-surface transition hover:text-theme-primary"
            title={"PinchYT #{@current_version}"}
          >
            PinchYT
          </.link>
          <.version_chip
            label={pinchyt_chip_label(@status)}
            tooltip={pinchyt_chip_tooltip(@status)}
            warning={match?({:update_available, _, _}, @status)}
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
       current_version: AppReleaseCheck.current_version(),
       policy: policy,
       pinned_version: Settings.get!(:yt_dlp_pinned_version),
       yt_dlp_version: Settings.get!(:yt_dlp_version) || "unknown"
     })}
  end

  attr :label, :string, required: true
  attr :tooltip, :string, required: true
  attr :warning, :boolean, default: false

  defp version_chip(assigns) do
    ~H"""
    <span
      class={[
        "group relative inline-flex max-w-full shrink items-center gap-0.5 rounded-full px-1.5 py-0.5",
        "text-center text-[0.6875rem] font-medium leading-none",
        if(@warning,
          do: "theme-badge-warning",
          else: "bg-theme-primary text-theme-on-primary"
        )
      ]}
      title={@tooltip}
      aria-label={@tooltip}
    >
      <span class="truncate">{@label}</span>
      <span :if={@warning} aria-hidden="true">!</span>
    </span>
    """
  end

  defp pinchyt_chip_label({:latest, _current}), do: "Latest"

  defp pinchyt_chip_label({:update_available, current, _latest}), do: current

  defp pinchyt_chip_tooltip({:latest, current}), do: current

  defp pinchyt_chip_tooltip({:update_available, _current, latest}) do
    "Update available: #{latest}"
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
