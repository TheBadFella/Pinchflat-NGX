defmodule PinchflatWeb.ProxySecurityTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias PinchflatWeb.Plugs.ProxyScheme

  setup do
    keys = [:trusted_proxy_ips, :allow_iframe_embed, :iframe_allowed_origins]
    old = Map.new(keys, &{&1, Application.fetch_env(:pinchflat, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:pinchflat, key, value)
        {key, :error} -> Application.delete_env(:pinchflat, key)
      end)
    end)

    :ok
  end

  test "only allowlisted peers can apply a single valid forwarded scheme" do
    Application.put_env(:pinchflat, :trusted_proxy_ips, [{127, 0, 0, 1}])
    trusted = %{conn(:get, "/") | remote_ip: {127, 0, 0, 1}} |> put_req_header("x-forwarded-proto", "https")
    assert ProxyScheme.call(trusted, []).scheme == :https
    untrusted = %{trusted | remote_ip: {10, 0, 0, 9}}
    assert ProxyScheme.call(untrusted, []).scheme == :http
    assert ProxyScheme.call(put_req_header(trusted, "x-forwarded-proto", "https,http"), []).scheme == :http
    assert ProxyScheme.call(put_req_header(trusted, "x-forwarded-proto", "javascript"), []).scheme == :http
  end

  test "legacy URL generation does not elevate the cookie connection scheme" do
    Application.delete_env(:pinchflat, :trusted_proxy_ips)
    result = conn(:get, "/") |> put_req_header("x-forwarded-proto", "https") |> ProxyScheme.call([])
    assert result.scheme == :http
    assert result.private.router_scheme == "https"
  end

  test "embedding defaults remain compatible and restricted origins preserve other CSP directives" do
    Application.put_env(:pinchflat, :allow_iframe_embed, true)
    Application.put_env(:pinchflat, :iframe_allowed_origins, [])

    base =
      conn(:get, "/")
      |> put_resp_header("x-frame-options", "SAMEORIGIN")
      |> put_resp_header("content-security-policy", "default-src 'self'")

    assert get_resp_header(PinchflatWeb.Plugs.allow_iframe_embed(base, []), "x-frame-options") == []
    Application.put_env(:pinchflat, :iframe_allowed_origins, ["https://dashboard.example"])
    result = PinchflatWeb.Plugs.allow_iframe_embed(base, [])

    assert get_resp_header(result, "content-security-policy") == [
             "default-src 'self'; frame-ancestors 'self' https://dashboard.example"
           ]

    Application.put_env(:pinchflat, :allow_iframe_embed, false)
    strict = PinchflatWeb.Plugs.allow_iframe_embed(base, [])
    assert get_resp_header(strict, "x-frame-options") == ["SAMEORIGIN"]
    assert get_resp_header(strict, "content-security-policy") == ["default-src 'self'; frame-ancestors 'self'"]
  end
end
