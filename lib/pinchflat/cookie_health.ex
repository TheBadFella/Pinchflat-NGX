defmodule Pinchflat.CookieHealth do
  @moduledoc """
  Coordinates truthful cookie health monitoring, snapshot isolation,
  periodic and on-demand health probing, status persistence, and Apprise alert dispatch.
  """

  require Logger

  alias Pinchflat.Settings
  alias Pinchflat.Settings.CookieFile
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils
  alias Pinchflat.YtDlp.Media
  alias Pinchflat.YtDlp.ResponseDecoder

  @topic "cookie_health"

  @doc """
  Calculates the SHA256 hex digest of the current cookies file.
  Returns `nil` if the file does not exist or is empty.
  """
  def cookie_digest do
    if CookieFile.present?() do
      case CookieFile.read() do
        {:ok, contents} ->
          if String.trim(contents) == "" do
            nil
          else
            :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  @doc """
  Executes a function with an isolated snapshot copy (mode 0600) of the current
  cookies file. Cleans up the temporary snapshot in an after block.

  Returns the result of the function, or `{:error, :not_configured}` if no cookie file exists.
  """
  def with_cookie_snapshot(fun) when is_function(fun, 1) do
    cookie_path = CookieFile.filepath()

    if FSUtils.exists_and_nonempty?(cookie_path) do
      tmp_id = Ecto.UUID.generate()
      tmp_path = Path.join(System.tmp_dir!(), "pinchflat_cookie_probe_#{tmp_id}.txt")

      caller = self()

      cleaner =
        spawn(fn ->
          Process.flag(:priority, :high)
          ref = Process.monitor(caller)

          receive do
            {:DOWN, ^ref, :process, _pid, _reason} ->
              File.rm(tmp_path)

            :done ->
              File.rm(tmp_path)
          end
        end)

      try do
        content = File.read!(cookie_path)
        File.write!(tmp_path, content, [:write, :binary, mode: 0o600])
        File.chmod!(tmp_path, 0o600)
        fun.(tmp_path)
      after
        send(cleaner, :done)
        File.rm(tmp_path)
      end
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Evaluates cookie health using offline validation and bounded canary probing.

  Returns `{:ok, map()}` with `:status`, `:error`, and `:details`.
  """
  def check_health(opts \\ []) do
    setting = Settings.record()
    canary_url = Keyword.get(opts, :canary_url, setting.cookie_health_canary_url)
    canary_url = if is_binary(canary_url), do: String.trim(canary_url), else: nil
    canary_url = if canary_url == "", do: nil, else: canary_url

    case CookieFile.validate() do
      {:error, :empty} ->
        {:ok,
         %{
           status: "not_configured",
           error: nil,
           details: "No cookies file present or file is empty"
         }}

      {:error, :invalid} ->
        {:ok,
         %{
           status: "malformed",
           error: "Not a valid Netscape cookies format",
           details: "File contains invalid lines or is unparseable"
         }}

      {:ok, %{active: 0, expired: expired, total: total}} when expired > 0 ->
        {:ok,
         %{
           status: "expired",
           error: "All #{total} cookies in jar are expired",
           details: "All #{total} cookies expired"
         }}

      {:ok, %{active: active, expired: expired, total: total}} ->
        if is_nil(canary_url) do
          {:ok,
           %{
             status: "auth_unverified",
             error: nil,
             details:
               "Cookies are structurally valid (#{active} active, #{expired} expired of #{total}), " <>
                 "but no canary URL configured to verify authentication."
           }}
        else
          probe_canary(canary_url, opts)
        end
    end
  end

  defp probe_canary(url, _opts) do
    runner = Application.get_env(:pinchflat, :yt_dlp_runner, Pinchflat.YtDlp.CommandRunner)

    result =
      with_cookie_snapshot(fn snapshot_path ->
        run_opts = [
          cookies_filepath: snapshot_path,
          skip_sleep_interval: true,
          logging_arg_override: "[cookie health probe arguments withheld]",
          log_output: false,
          output_transform: &sanitize_canary_output/1,
          expected_exit_codes: [1, 2]
        ]

        output_template = Media.indexing_output_template()

        case runner.run(url, :get_media_attributes, [:simulate, :skip_download], output_template, run_opts) do
          {:ok, output} ->
            handle_canary_success(url, output, runner)

          {:error, output, status} ->
            handle_canary_error(output, status)

          {:error, err} when is_binary(err) ->
            handle_canary_error(err, 1)

          {:error, err} ->
            handle_canary_error(inspect(err), 1)
        end
      end)

    case result do
      {:error, :not_configured} ->
        {:ok,
         %{
           status: "not_configured",
           error: nil,
           details: "No cookies file present or file is empty"
         }}

      other ->
        other
    end
  end

  @doc false
  def sanitize_canary_url(url) when is_binary(url) do
    Regex.replace(~r/([?&](?!v=)[a-zA-Z0-9_.-]+)=[^&\s]+/i, url, "\\1=[REDACTED]")
  end

  def sanitize_canary_url(other), do: other

  @doc false
  def sanitize_canary_output(output) when is_binary(output) do
    output
    |> String.replace(~r/([?&][a-zA-Z0-9_.-]+)=[^&\s\n\r"']+/i, "\\1=[REDACTED]")
    |> String.replace(~r/pinchflat_cookie_probe_[a-zA-Z0-9_-]+\.txt/i, "pinchflat_cookie_probe_[REDACTED].txt")
  end

  def sanitize_canary_output(other), do: other

  defp extract_video_id(url) when is_binary(url) do
    cond do
      match = Regex.run(~r/[?&]v=([a-zA-Z0-9_-]+)/, url) -> List.last(match)
      match = Regex.run(~r/youtu\.be\/([a-zA-Z0-9_-]+)/, url) -> List.last(match)
      match = Regex.run(~r/youtube\.com\/shorts\/([a-zA-Z0-9_-]+)/, url) -> List.last(match)
      true -> nil
    end
  end

  defp extract_video_id(_), do: nil

  defp handle_canary_success(url, output, runner) do
    case ResponseDecoder.decode(output, :get_media_attributes) do
      {:ok, parsed} ->
        expected_id = extract_video_id(url)
        parsed_id = parsed["id"]

        if is_nil(expected_id) or is_nil(parsed_id) or parsed_id != expected_id do
          {:ok,
           %{
             status: "auth_unverified",
             error: nil,
             details: "Extracted video ID is missing or does not match configured canary video ID."
           }}
        else
          availability = Media.normalize_availability(parsed["availability"])

          cond do
            availability in [:subscriber_only, :premium_only, :needs_auth, :private] ->
              {:ok,
               %{
                 status: "authenticated",
                 error: nil,
                 details: "Authenticated successfully against #{availability} canary media."
               }}

            availability in [:public, :unlisted] ->
              {:ok,
               %{
                 status: "auth_unverified",
                 error: nil,
                 details:
                   "Canary media is public/unlisted; extraction succeeded but does not verify authenticated cookie health."
               }}

            true ->
              probe_without_cookies(url, runner)
          end
        end

      _ ->
        {:ok,
         %{
           status: "auth_unverified",
           error: nil,
           details: "Canary extracted but metadata could not be decoded."
         }}
    end
  end

  defp probe_without_cookies(url, runner) do
    output_template = Media.indexing_output_template()

    no_cookie_opts = [
      use_cookies: false,
      skip_sleep_interval: true,
      logging_arg_override: "[cookie health probe arguments withheld]",
      log_output: false,
      output_transform: &sanitize_canary_output/1,
      expected_exit_codes: [1, 2]
    ]

    case runner.run(url, :get_media_attributes, [:simulate, :skip_download], output_template, no_cookie_opts) do
      {:ok, _} ->
        {:ok,
         %{
           status: "auth_unverified",
           error: nil,
           details:
             "Canary media is accessible without cookies; extraction does not verify authenticated cookie health."
         }}

      {:error, output, _status} ->
        err_str = to_string(output)

        cond do
          network_error?(err_str) ->
            {:ok,
             %{
               status: "auth_unverified",
               error: nil,
               details: "Without-cookies probe encountered network error; cannot affirmatively verify authentication."
             }}

          affirmative_auth_required?(err_str) ->
            {:ok,
             %{
               status: "authenticated",
               error: nil,
               details: "Authenticated successfully (canary requires authentication and succeeded with cookies)."
             }}

          true ->
            {:ok,
             %{
               status: "auth_unverified",
               error: nil,
               details: "Without-cookies probe returned inconclusive error; cannot verify authentication."
             }}
        end
    end
  end

  defp affirmative_auth_required?(str) do
    patterns = [
      "sign in",
      "login required",
      "private video",
      "requires authentication"
    ]

    lower = String.downcase(str)
    Enum.any?(patterns, &String.contains?(lower, &1)) and not bot_challenge?(str)
  end

  defp handle_canary_error(output, _status) do
    str = to_string(output)

    cond do
      bot_challenge?(str) ->
        {:ok,
         %{
           status: "canary_unavailable",
           error: "Bot challenge or verification required during probe.",
           details: "Bot challenge encountered; cookies cannot be conclusively diagnosed."
         }}

      entitlement_error?(str) ->
        {:ok,
         %{
           status: "canary_unavailable",
           error: "Membership or channel subscription required for canary media.",
           details: "Channel membership required; cookies cannot be conclusively diagnosed."
         }}

      canary_unavailable?(str) ->
        {:ok,
         %{
           status: "canary_unavailable",
           error: "Canary media is unavailable or deleted.",
           details: "Canary media cannot be found or has been removed."
         }}

      network_error?(str) ->
        {:ok,
         %{
           status: "network_error",
           error: "Network error or rate limit during probe.",
           details: "Probe encountered network connectivity or rate limit issue."
         }}

      auth_rejection?(str) ->
        {:ok,
         %{
           status: "authentication_rejected",
           error: "YouTube authentication rejected: cookies expired or account sign-in required.",
           details: "Authentication rejected by YouTube for canary media."
         }}

      true ->
        {:ok,
         %{
           status: "canary_unavailable",
           error: "Canary extraction failed.",
           details: "Canary extraction encountered an unclassified failure."
         }}
    end
  end

  defp bot_challenge?(str) do
    patterns = [
      "confirm you're not a bot",
      "confirm you’re not a bot",
      "not a bot",
      "bot detection"
    ]

    lower = String.downcase(str)
    Enum.any?(patterns, &String.contains?(lower, &1))
  end

  defp entitlement_error?(str) do
    patterns = [
      "members-only",
      "channel's members",
      "join this channel"
    ]

    lower = String.downcase(str)
    Enum.any?(patterns, &String.contains?(lower, &1))
  end

  defp auth_rejection?(str) do
    patterns = [
      "cookies are expired",
      "account sign-in or authorization required",
      "invalid cookies",
      "cookie expired",
      "session expired"
    ]

    lower = String.downcase(str)
    Enum.any?(patterns, &String.contains?(lower, &1)) and not bot_challenge?(str) and not entitlement_error?(str)
  end

  defp canary_unavailable?(str) do
    patterns = [
      "video unavailable",
      "this video does not exist",
      "has been removed",
      "account associated with this video has been terminated",
      "not found",
      "404"
    ]

    lower = String.downcase(str)
    Enum.any?(patterns, &String.contains?(lower, &1))
  end

  defp network_error?(str) do
    patterns = [
      "429",
      "too many requests",
      "timed out",
      "temporary failure in name resolution",
      "connection refused",
      "network is unreachable"
    ]

    lower = String.downcase(str)
    Enum.any?(patterns, &String.contains?(lower, &1))
  end

  @doc """
  Runs health check, persists status and timestamps to Settings,
  dispatches deduplicated Apprise notification if in failure state,
  and broadcasts the result on PubSub.
  """
  def perform_check_and_update(opts \\ []) do
    initial_digest = cookie_digest()
    {:ok, result} = check_health(opts)
    current_digest = cookie_digest()

    if initial_digest != current_digest do
      Logger.info("[CookieHealth] Cookie file changed during probe; discarding stale result.")
      {:ok, Settings.record(), %{status: "stale_discarded", error: nil, details: "Cookie file changed during probe"}}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      setting = Settings.record()

      attrs = %{
        cookie_health_status: result.status,
        cookie_health_last_checked_at: now,
        cookie_health_last_error: result.error,
        cookie_health_cookie_digest: current_digest
      }

      attrs =
        if result.status == "authenticated" do
          Map.put(attrs, :cookie_health_last_authenticated_at, now)
        else
          attrs
        end

      attrs =
        if result.status in ["authenticated", "auth_unverified"] do
          Map.put(attrs, :cookie_health_alert_sent_for_digest, nil)
        else
          attrs
        end

      should_alert? =
        result.status in ["expired", "malformed", "authentication_rejected"] and
          setting.cookie_health_alert_sent_for_digest != current_digest and
          current_digest != nil and
          not blank?(setting.apprise_server)

      attrs =
        if should_alert? do
          case dispatch_apprise_alert(setting.apprise_server, result, setting) do
            {:ok, _} ->
              Map.put(attrs, :cookie_health_alert_sent_for_digest, current_digest)

            _ ->
              attrs
          end
        else
          attrs
        end

      case Settings.update_setting(setting, attrs) do
        {:ok, updated_setting} ->
          broadcast({:cookie_health_updated, updated_setting, result})
          {:ok, updated_setting, result}

        {:error, changeset} ->
          Logger.error("Failed to update cookie health settings: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
  end

  defp dispatch_apprise_alert(server, result, setting) do
    title = "[Pinchflat-ngx] YouTube Cookie Issue Detected"

    status_desc =
      case result.status do
        "expired" -> "Your YouTube cookies have expired"
        "malformed" -> "Your YouTube cookies file is malformed or invalid"
        "authentication_rejected" -> "YouTube rejected authentication with your current cookies"
        _ -> "A YouTube cookie health issue occurred"
      end

    body = "**Status**: ⚠️ #{status_desc}."

    body =
      if result.error do
        "#{body}\n**Details**: `#{result.error}`"
      else
        body
      end

    body =
      case setting.external_base_url do
        url when is_binary(url) and url != "" ->
          "#{body}\n\n[Update cookies in Pinchflat Settings](#{String.trim_trailing(url, "/")}/settings)"

        _ ->
          "#{body}\n\nPlease update your cookies file in Pinchflat Settings."
      end

    apprise_runner =
      Application.get_env(:pinchflat, :apprise_runner, Pinchflat.Lifecycle.Notifications.CommandRunner)

    opts = [
      title: title,
      body: body,
      input_format: "markdown",
      notification_type: "failure"
    ]

    case apprise_runner.run([server], opts) do
      {:ok, res} ->
        Logger.info("[CookieHealth] Sent Apprise cookie health alert")
        {:ok, res}

      {:error, reason} ->
        Logger.error("[CookieHealth] Failed to send Apprise cookie health alert: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Subscribes the calling process to cookie health update events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Pinchflat.PubSub, @topic)
  end

  @doc """
  Broadcasts a cookie health message to subscribers.
  """
  def broadcast(message) do
    Phoenix.PubSub.broadcast(Pinchflat.PubSub, @topic, message)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false
end
