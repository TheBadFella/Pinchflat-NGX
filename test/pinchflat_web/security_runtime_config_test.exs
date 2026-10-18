defmodule PinchflatWeb.SecurityRuntimeConfigTest do
  use ExUnit.Case, async: false

  setup do
    keys = ~w(TRUSTED_PROXY_IPS SECURE_SESSION_COOKIE ALLOW_IFRAME_EMBED IFRAME_ALLOWED_ORIGINS)
    old = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(old, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "exact proxy addresses and safe dashboard origins are accepted" do
    System.put_env("TRUSTED_PROXY_IPS", "127.0.0.1, ::1")
    System.put_env("IFRAME_ALLOWED_ORIGINS", "https://dashboard.example,http://192.168.1.2:3000/")
    config = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)[:pinchflat]
    assert config[:trusted_proxy_ips] == [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
    assert config[:iframe_allowed_origins] == ["https://dashboard.example", "http://192.168.1.2:3000"]
    assert config[:allow_iframe_embed]
    refute config[:force_secure_session_cookie]
  end

  test "invalid security configuration fails rather than silently weakening the policy" do
    for {key, value} <- [
          {"TRUSTED_PROXY_IPS", "0.0.0.0/0"},
          {"SECURE_SESSION_COOKIE", "treu"},
          {"ALLOW_IFRAME_EMBED", "flase"},
          {"IFRAME_ALLOWED_ORIGINS", "https://user:password@dashboard.example"},
          {"IFRAME_ALLOWED_ORIGINS", "https://dashboard.example/path"},
          {"IFRAME_ALLOWED_ORIGINS", "https://dashboard.example;script-src"}
        ] do
      System.put_env(key, value)
      assert_raise ArgumentError, fn -> Config.Reader.read!("config/runtime.exs", env: :test, target: :host) end
      System.delete_env(key)
    end
  end
end
