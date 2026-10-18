defmodule Pinchflat.AppReleaseCheck do
  @moduledoc """
  Compares the running Pinchflat-ngx version with the latest GitHub release so the
  sidebar can show when an update is available.
  """

  alias Pinchflat.Utils.VersionUtils

  @repo_api "https://api.github.com/repos/TheBadFella/pinchflat-ngx"
  @headers [{"User-Agent", "Pinchflat-ngx"}, {"Accept", "application/vnd.github+json"}]
  @cache_key {__MODULE__, :latest}
  @cache_ttl_ms :timer.hours(6)

  @doc """
  Returns the version string compiled into this release.
  """
  def current_version do
    :pinchflat
    |> Application.spec(:vsn)
    |> to_string()
  end

  @doc """
  Returns the configured build track (`"stable"` or `"dev"`).
  """
  def build_track do
    Application.get_env(:pinchflat, :build_track, "stable")
  end

  @doc """
  Returns whether this instance is running a development build.
  """
  def dev? do
    build_track() == "dev"
  end

  @doc """
  Returns the commit SHA embedded in this build, or nil if not set.
  """
  def build_sha do
    case Application.get_env(:pinchflat, :build_sha) do
      sha when is_binary(sha) ->
        case String.trim(sha) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns a human-readable display version.
  For dev builds, appends the dev tag and short commit SHA if available.
  """
  def display_version do
    base = current_version()

    if dev?() do
      case build_sha() do
        sha when is_binary(sha) and sha != "" ->
          "#{base} (dev-#{String.slice(sha, 0, 7)})"

        _ ->
          "#{base} (dev)"
      end
    else
      base
    end
  end

  @doc """
  Returns `{:dev, sha}` when running a development build.
  Returns `{:latest, current}` when this install matches or is ahead of GitHub,
  or `{:update_available, current, latest}` when GitHub has a newer tag.

  Network failures fail closed to `{:latest, current}` so the UI does not
  warn when it cannot tell.

  Returns `{:dev, binary() | nil} | {:latest, binary()} | {:update_available, binary(), binary()}`
  """
  def status do
    if dev?() do
      {:dev, build_sha()}
    else
      current = current_version()

      case latest_version() do
        {:ok, latest} ->
          if VersionUtils.compare(current, latest) == :lt do
            {:update_available, current, latest}
          else
            {:latest, current}
          end

        {:error, _reason} ->
          {:latest, current}
      end
    end
  end

  @doc """
  Returns `{:ok, binary()} | {:error, term()}`
  """
  def latest_version do
    if Application.get_env(:pinchflat, :app_release_check, true) do
      do_latest_version()
    else
      {:ok, current_version()}
    end
  end

  @doc false
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp do_latest_version do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, :miss) do
      {version, expires_at} when is_binary(version) and now < expires_at ->
        {:ok, version}

      _ ->
        fetch_and_cache()
    end
  end

  defp fetch_and_cache do
    case http_client().get("#{@repo_api}/releases/latest", @headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"tag_name" => tag}} ->
            version = normalize_tag(tag)
            expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
            :persistent_term.put(@cache_key, {version, expires_at})
            {:ok, version}

          _ ->
            {:error, :unexpected_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_tag(tag) do
    tag
    |> to_string()
    |> String.trim()
    |> String.trim_leading("v")
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
