defmodule PinchflatWeb.SessionSecurityTest do
  use PinchflatWeb.ConnCase, async: false

  setup do
    keys = [:trusted_proxy_ips, :force_secure_session_cookie]
    old = Map.new(keys, &{&1, Application.fetch_env(:pinchflat, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:pinchflat, key, value)
        {key, :error} -> Application.delete_env(:pinchflat, key)
      end)
    end)

    :ok
  end

  test "secure cookies are opt-in on direct HTTP and honor trusted HTTPS proxies", %{conn: conn} do
    Application.put_env(:pinchflat, :trusted_proxy_ips, [])
    Application.put_env(:pinchflat, :force_secure_session_cookie, false)
    direct = get(conn, "/settings")
    [cookie] = get_resp_header(direct, "set-cookie")
    refute cookie =~ "secure"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"

    Application.put_env(:pinchflat, :force_secure_session_cookie, true)
    forced = get(build_conn(), "/settings")
    assert Enum.any?(get_resp_header(forced, "set-cookie"), &String.contains?(&1, "secure"))

    Application.put_env(:pinchflat, :force_secure_session_cookie, false)
    Application.put_env(:pinchflat, :trusted_proxy_ips, [{127, 0, 0, 1}])

    trusted =
      %{build_conn() | remote_ip: {127, 0, 0, 1}} |> put_req_header("x-forwarded-proto", "https") |> get("/settings")

    assert Enum.any?(get_resp_header(trusted, "set-cookie"), &String.contains?(&1, "secure"))

    untrusted =
      %{build_conn() | remote_ip: {10, 0, 0, 7}} |> put_req_header("x-forwarded-proto", "https") |> get("/settings")

    refute Enum.any?(get_resp_header(untrusted, "set-cookie"), &String.contains?(&1, "secure"))
  end
end
