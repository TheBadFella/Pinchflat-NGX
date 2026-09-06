defmodule PinchflatWeb.OIDC do
  @moduledoc """
  Reads the optional OIDC/SSO application configuration and builds the
  assent provider config. When `OIDC_ISSUER`, `OIDC_CLIENT_ID`, and
  `OIDC_CLIENT_SECRET` are not all set, SSO is disabled and the app
  behaves exactly as it did without this feature.
  """

  @session_key :sso_user

  @doc """
  Returns the session key under which the signed-in SSO user is stored.
  """
  @spec session_key() :: atom()
  def session_key, do: @session_key

  @doc """
  Returns true when SSO is configured and enabled.

  Returns false when the `:oidc` application env is nil (the default).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:pinchflat, :oidc) != nil

  @doc """
  Builds assent config. `redirect_uri` is required for both authorize and
  callback phases; it is derived from the request (the endpoint already
  rewrites the router URL from x-forwarded-* headers) unless the operator
  pinned it via OIDC_REDIRECT_URI.

  Returns nil when SSO is not configured.
  """
  @spec provider_config(String.t() | nil, keyword()) :: keyword() | nil
  def provider_config(redirect_uri, overrides \\ []) do
    cfg = Application.get_env(:pinchflat, :oidc)

    if cfg do
      [
        client_id: cfg[:client_id],
        client_secret: cfg[:client_secret],
        base_url: cfg[:issuer],
        redirect_uri: redirect_uri,
        client_authentication_method: cfg[:client_authentication_method],
        authorization_params: [scope: cfg[:scopes]],
        code_verifier: true,
        # assent expects the client to supply the nonce value itself
        # (a boolean `true` would be used verbatim); it lands in both the
        # authorization params and the session params for later validation.
        nonce: generate_nonce(),
        http_adapter: Assent.HTTPAdapter.Req
      ]
      # Test-only knobs: allow injecting a static discovery document, a
      # non-default JWT alg, and a stub HTTP adapter without network calls.
      |> Keyword.merge(Keyword.take(cfg, [:openid_configuration, :id_token_signed_response_alg, :http_adapter]))
      |> Keyword.merge(overrides)
    end
  end

  @doc """
  Display name for the login button. Returns nil when SSO is disabled.
  """
  @spec provider_name() :: String.t() | nil
  def provider_name, do: Application.get_env(:pinchflat, :oidc)[:provider_name]

  defp generate_nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
