defmodule PinchflatWeb.Api.ShareController do
  use PinchflatWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Pinchflat.ShareTokens
  alias Pinchflat.ShareTokens.RateLimiter
  alias Pinchflat.ShareTokens.ShareToken
  alias Pinchflat.YoutubeBrowser.Intake
  alias Pinchflat.YoutubeBrowser.UrlParser
  alias PinchflatWeb.Schemas

  tags(["Share Intake"])

  operation(:intake,
    operation_id: "Api.ShareController.intake",
    security: [%{"shareToken" => []}],
    summary: "Intake YouTube video via scoped share token",
    description: """
    Enqueues a single YouTube video URL for normal download intake using a scoped,
    profile-bound share token provided in the Authorization header. Overrides to profile
    or forced downloads are strictly forbidden. Rate limited to 10 requests per minute
    per token. Request body is bounded to 8KiB.
    """,
    request_body: {"Share intake parameters", "application/json", Schemas.ShareIntakeRequest, required: true},
    responses: [
      accepted: {"Video accepted and queued", "application/json", Schemas.ShareIntakeResponse},
      bad_request:
        {"Invalid request payload or override attempt", "application/json", Schemas.ShareIntakeErrorResponse},
      unauthorized: {"Missing, invalid, or revoked token", "application/json", Schemas.ShareIntakeErrorResponse},
      conflict: {"Video already downloaded or in queue", "application/json", Schemas.ShareIntakeErrorResponse},
      request_entity_too_large:
        {"Request body exceeds 8KiB limit", "application/json", Schemas.ShareIntakeErrorResponse},
      unsupported_media_type: {"Use application/json", "application/json", Schemas.ShareIntakeErrorResponse},
      unprocessable_entity: {
        "Invalid video URL or policy blocked",
        "application/json",
        Schemas.ShareIntakeErrorResponse
      },
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.ShareIntakeErrorResponse},
      service_unavailable: {"Migration hold active", "application/json", Schemas.ShareIntakeErrorResponse}
    ]
  )

  @max_body_bytes 8192

  def intake(conn, params) do
    with :ok <- validate_body_size(conn),
         {:ok, share_token} <- authenticate_request(conn),
         :ok <- validate_intake_params(params),
         :ok <- check_migration_hold(),
         {:ok, parsed} <- parse_target_url(params["url"]),
         :ok <- ShareTokens.validate_mutation_boundary(share_token) do
      execute_intake(conn, parsed, share_token)
    else
      {:error, :payload_too_large} ->
        send_json_error(conn, 413, "payload_too_large", "Request body exceeds 8KiB limit")

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_status(429)
        |> json(%{
          error: "rate_limited",
          message: "Rate limit exceeded. Please wait before retrying.",
          retry_after: retry_after
        })

      {:error, :unauthorized, message} ->
        send_json_error(conn, 401, "unauthorized", message)

      {:error, :revoked_token} ->
        send_json_error(conn, 401, "revoked_token", "This share token has been revoked")

      {:error, reason} when reason in [:revoked, :expired, :invalid_token] ->
        send_json_error(conn, 401, "unauthorized", "Share token is no longer active")

      {:error, :profile_deleted} ->
        send_json_error(conn, 422, "invalid_profile", "Bound media profile no longer exists")

      {:error, :invalid_profile} ->
        send_json_error(conn, 422, "invalid_profile", "Bound media profile no longer exists")

      {:error, :override_rejected} ->
        send_json_error(
          conn,
          400,
          "override_rejected",
          "Tokens are strictly bound to their assigned media profile. Overrides are not permitted."
        )

      {:error, :invalid_request, message} ->
        send_json_error(conn, 400, "invalid_request", message)

      {:error, :migration_hold_active} ->
        send_json_error(conn, 503, "migration_hold_active", "Database migration review or transfer in progress")

      {:error, :channel_or_playlist_not_supported, message} ->
        send_json_error(conn, 422, "channel_or_playlist_not_supported", message)

      {:error, :invalid_url, message} ->
        send_json_error(conn, 422, "invalid_url", message)
    end
  end

  defp validate_body_size(conn) do
    content_length =
      case get_req_header(conn, "content-length") do
        [val] ->
          case Integer.parse(val) do
            {len, _} -> len
            :error -> 0
          end

        _ ->
          0
      end

    if content_length > @max_body_bytes do
      {:error, :payload_too_large}
    else
      :ok
    end
  end

  defp authenticate_request(conn) do
    client_ip = conn.remote_ip

    case RateLimiter.check_invalid_auth(client_ip) do
      {:error, :rate_limited, retry_after} ->
        {:error, :rate_limited, retry_after}

      :ok ->
        do_authenticate(conn, client_ip)
    end
  end

  defp do_authenticate(conn, client_ip) do
    case get_req_header(conn, "authorization") do
      [auth_header] ->
        token = extract_bearer_token(auth_header)

        if is_nil(token) or token == "" do
          RateLimiter.record_invalid_auth(client_ip)
          {:error, :unauthorized, "Missing authorization token in Authorization header"}
        else
          verify_token(token, client_ip)
        end

      [] ->
        RateLimiter.record_invalid_auth(client_ip)
        {:error, :unauthorized, "Authorization header is required"}

      _multiple_or_malformed ->
        RateLimiter.record_invalid_auth(client_ip)
        {:error, :unauthorized, "Invalid or duplicate Authorization header"}
    end
  end

  defp verify_token(token, client_ip) do
    case ShareTokens.authenticate(token) do
      {:ok, %ShareToken{} = share_token} ->
        case RateLimiter.check_intake(share_token.token_digest) do
          :ok -> {:ok, share_token}
          {:error, :rate_limited, retry_after} -> {:error, :rate_limited, retry_after}
        end

      {:error, :revoked} ->
        RateLimiter.record_invalid_auth(client_ip)
        {:error, :revoked_token}

      {:error, :expired} ->
        RateLimiter.record_invalid_auth(client_ip)
        {:error, :expired}

      {:error, :profile_deleted} ->
        {:error, :invalid_profile}

      {:error, :invalid_token} ->
        RateLimiter.record_invalid_auth(client_ip)
        {:error, :unauthorized, "Invalid authorization token"}
    end
  end

  defp extract_bearer_token(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] when scheme in ["Bearer", "bearer", "Token", "token"] ->
        trimmed = String.trim(token)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp extract_bearer_token(_), do: nil

  defp validate_intake_params(params) when is_map(params) do
    forbidden_keys = ["profile_id", "media_profile_id", "force", "format", "quality", "path"]

    has_override = Enum.any?(forbidden_keys, &Map.has_key?(params, &1))

    cond do
      has_override ->
        {:error, :override_rejected}

      not is_binary(params["url"]) or String.trim(params["url"]) == "" ->
        {:error, :invalid_request, "Request body must contain a non-empty 'url' string field"}

      true ->
        :ok
    end
  end

  defp validate_intake_params(_), do: {:error, :invalid_request, "Request body must be a JSON object"}

  defp check_migration_hold do
    if Intake.migration_hold_active?() do
      {:error, :migration_hold_active}
    else
      :ok
    end
  end

  defp parse_target_url(raw_url) do
    case UrlParser.parse(raw_url) do
      {:ok, %{video_id: video_id, canonical_url: canonical_url}} ->
        {:ok, %{video_id: video_id, canonical_url: canonical_url}}

      {:error, {:channel_or_playlist, msg}} ->
        {:error, :channel_or_playlist_not_supported, msg}

      {:error, reason} ->
        {:error, :invalid_url, "Invalid YouTube video URL: #{friendly_url_error(reason)}"}
    end
  end

  defp execute_intake(conn, %{video_id: video_id, canonical_url: canonical_url}, %ShareToken{} = share_token) do
    case Intake.download_video(video_id, share_token.media_profile_id) do
      {:ok, :queued} ->
        conn
        |> put_status(202)
        |> json(%{
          status: "queued",
          video_id: video_id,
          canonical_url: canonical_url,
          media_profile_id: share_token.media_profile_id,
          message: "Video queued for download"
        })

      {:ok, :queued_paused} ->
        conn
        |> put_status(202)
        |> json(%{
          status: "queued_paused",
          video_id: video_id,
          canonical_url: canonical_url,
          media_profile_id: share_token.media_profile_id,
          message: "Video queued in paused queue"
        })

      {:ok, :indexing} ->
        conn
        |> put_status(202)
        |> json(%{
          status: "indexing",
          video_id: video_id,
          canonical_url: canonical_url,
          media_profile_id: share_token.media_profile_id,
          message: "Video source created and indexing started"
        })

      {:error, :already_present} ->
        conn
        |> put_status(409)
        |> json(%{
          error: "already_present",
          video_id: video_id,
          message: "Video is already present in library"
        })

      {:error, :already_queued} ->
        conn
        |> put_status(409)
        |> json(%{
          error: "already_queued",
          video_id: video_id,
          message: "Video is already queued or downloading"
        })

      {:error, :migration_hold_active} ->
        send_json_error(conn, 503, "migration_hold_active", "Database migration review or transfer in progress")

      {:error, reason}
      when reason in [
             :source_disabled,
             :source_downloads_disabled,
             :download_prevented,
             :culled,
             :unavailable,
             :missing_file,
             :storage_unverified,
             :storage_inaccessible,
             :policy_ineligible,
             :ambiguous_copies
           ] ->
        conn
        |> put_status(422)
        |> json(%{
          error: "policy_blocked",
          reason: to_string(reason),
          message: "Download prevented by policy: #{reason}"
        })

      {:error, _reason} ->
        send_json_error(conn, 400, "intake_failed", "Download intake failed")
    end
  end

  defp send_json_error(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end

  defp friendly_url_error(:empty_url), do: "URL cannot be empty"
  defp friendly_url_error(:url_too_long), do: "URL exceeds maximum length of 2,048 characters"
  defp friendly_url_error(:unsupported_scheme), do: "URL must use HTTP or HTTPS scheme"
  defp friendly_url_error(:credentials_not_allowed), do: "URLs containing user credentials are not allowed"
  defp friendly_url_error(:non_default_port), do: "Non-default ports are not allowed"
  defp friendly_url_error(:unsupported_host), do: "Only YouTube video URLs are supported"
  defp friendly_url_error(:missing_video_id), do: "No valid YouTube video ID found in URL"
  defp friendly_url_error(:invalid_video_id), do: "Video ID is not a valid 11-character YouTube ID"
  defp friendly_url_error(:extra_path_segments), do: "URL path contains unexpected segments"
  defp friendly_url_error(:conflicting_video_id_parameters), do: "URL contains conflicting video ID parameters"
  defp friendly_url_error(:malformed_url), do: "URL could not be parsed"
  defp friendly_url_error(reason), do: to_string(reason)
end
