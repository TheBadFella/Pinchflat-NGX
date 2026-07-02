defmodule Pinchflat.YtDlp.UpdateManager do
  @moduledoc """
  Resolves the configured yt-dlp update policy into concrete yt-dlp update
  actions. Centralizes the difference between a one-shot "jump" (performed once,
  right after the user changes the setting) and the recurring behaviour run by
  the cron/boot `UpdateWorker`.

  Policies (stored in the `yt_dlp_update_policy` setting):

    - `"stable"` - track the latest stable release, updating daily (default)
    - `"nightly"` - track the latest nightly build, updating daily
    - `"nightly_frozen"` - jump to the latest nightly once and hold there,
      re-asserting that exact build on boot so an image swap can't drift it
    - `"nightly_until_stable"` - jump to the latest nightly once, hold there, and
      automatically revert to stable once a stable release catches up to (or
      passes) the nightly we landed on
    - `"pinned"` - install one exact version (`yt_dlp_pinned_version`) and hold
      there, re-asserting it on boot so an image swap can't drift it
  """

  require Logger

  alias Pinchflat.Settings
  alias Pinchflat.Utils.VersionUtils
  alias Pinchflat.YtDlp.ReleaseLookup

  @policies ~w(stable nightly nightly_frozen nightly_until_stable pinned)

  @doc "Returns the list of valid update policies"
  def policies, do: @policies

  @doc "Returns a human-friendly label for a policy, used in the UI"
  def humanize_policy("stable"), do: "Stable"
  def humanize_policy("nightly"), do: "Nightly"
  def humanize_policy("nightly_frozen"), do: "Nightly, frozen"
  def humanize_policy("nightly_until_stable"), do: "Nightly until stable"
  def humanize_policy("pinned"), do: "Pinned"
  def humanize_policy(_other), do: "Stable"

  @doc """
  Recurring update behaviour, run by the cron/boot worker. This is the
  steady-state for a policy and never performs the initial one-shot jump.

  The held policies (`pinned`, `nightly_frozen`, and `nightly_until_stable`
  while it's still holding) re-assert their target here rather than doing
  nothing. yt-dlp lives on the container's ephemeral filesystem, so
  replacing/recreating the image reverts it to whatever version was baked in.
  Re-asserting on every boot trues the binary back up to the version the
  settings say we should be on (yt-dlp no-ops cheaply if it already matches).

  Returns :ok
  """
  def run_scheduled_update do
    case Settings.get!(:yt_dlp_update_policy) do
      "stable" ->
        update_to_stable()

      "nightly" ->
        update_to("nightly")

      "nightly_until_stable" ->
        maybe_revert_to_stable()

      "nightly_frozen" ->
        reassert_frozen_nightly()

      "pinned" ->
        reassert_pinned_version()

      _unknown ->
        :noop
    end

    refresh_installed_version()
    :ok
  end

  @doc """
  Applies the currently-saved policy immediately, performing the one-shot jump
  to the target channel/version. Called right after the user saves the setting.

  Returns :ok
  """
  def apply_policy do
    case Settings.get!(:yt_dlp_update_policy) do
      "stable" ->
        update_to_stable()

      "nightly" ->
        update_to("nightly")

      # Record which nightly we landed on so a later boot can true the binary
      # back up to this exact build instead of drifting to the latest nightly.
      channel when channel in ["nightly_frozen", "nightly_until_stable"] ->
        update_to("nightly")
        capture_nightly_baseline()

      "pinned" ->
        reassert_pinned_version()
    end

    refresh_installed_version()
    :ok
  end

  defp reassert_pinned_version do
    case Settings.get!(:yt_dlp_pinned_version) do
      version when is_binary(version) and version != "" -> update_to(version)
      _blank -> Logger.warning("yt-dlp policy is 'pinned' but no version is set; skipping update")
    end
  end

  defp reassert_frozen_nightly do
    case Settings.get!(:yt_dlp_nightly_baseline) do
      version when is_binary(version) and version != "" ->
        update_to("nightly@" <> version)

      # We don't know which nightly was frozen (e.g. set before this was
      # tracked), so there's nothing safe to re-assert. Leave the binary as-is.
      _blank ->
        :noop
    end
  end

  defp maybe_revert_to_stable do
    baseline = Settings.get!(:yt_dlp_nightly_baseline) || Settings.get!(:yt_dlp_version)

    case ReleaseLookup.latest_stable_version() do
      {:ok, stable_version} ->
        if VersionUtils.compare(stable_version, baseline) in [:eq, :gt] do
          Logger.info("Stable yt-dlp #{stable_version} caught up to nightly #{baseline}; reverting to stable")
          update_to(stable_version)
          Settings.set(yt_dlp_update_policy: "stable")
          Settings.set(yt_dlp_nightly_baseline: nil)
        else
          Logger.info("Holding yt-dlp on nightly #{baseline}; latest stable #{stable_version} hasn't caught up")
          reassert_frozen_nightly()
        end

      {:error, reason} ->
        Logger.warning("Couldn't check latest stable yt-dlp version, staying on nightly: #{inspect(reason)}")
        reassert_frozen_nightly()
    end
  end

  defp capture_nightly_baseline do
    case yt_dlp_runner().version() do
      {:ok, version} -> Settings.set(yt_dlp_nightly_baseline: version)
      _error -> :noop
    end
  end

  # Targets the *exact* latest stable version rather than the `stable` channel.
  # yt-dlp's plain channel update (`--update`) refuses to move backwards, so if
  # the installed binary is a newer nightly (e.g. after switching off a frozen
  # nightly), a channel update would no-op and strand us on that nightly.
  # Pinning the resolved version forces yt-dlp to downgrade. Falls back to the
  # channel update if the GitHub lookup is unavailable.
  defp update_to_stable do
    case ReleaseLookup.latest_stable_version() do
      {:ok, stable_version} ->
        update_to(stable_version)

      {:error, reason} ->
        Logger.warning(
          "Couldn't resolve latest stable yt-dlp version, falling back to channel update: #{inspect(reason)}"
        )

        update_to("stable")
    end
  end

  defp update_to(target) do
    Logger.info("Updating yt-dlp (target: #{target})")

    case yt_dlp_runner().update(target) do
      {:ok, _output} = result ->
        result

      {:error, reason} = error ->
        Logger.error("yt-dlp update to '#{target}' failed: #{inspect(reason)}")
        error
    end
  end

  defp refresh_installed_version do
    case yt_dlp_runner().version() do
      {:ok, version} -> Settings.set(yt_dlp_version: version)
      _error -> :noop
    end
  end

  defp yt_dlp_runner do
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
