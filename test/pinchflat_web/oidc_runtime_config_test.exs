defmodule PinchflatWeb.OIDCRuntimeConfigTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @oidc_env_vars ~w(
    OIDC_ISSUER
    OIDC_CLIENT_ID
    OIDC_CLIENT_SECRET
    OIDC_SCOPES
    OIDC_CLIENT_AUTH_METHOD
    OIDC_PROVIDER_NAME
    OIDC_REDIRECT_URI
  )

  setup do
    previous_values = Map.new(@oidc_env_vars, &{&1, System.get_env(&1)})
    Enum.each(@oidc_env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "leaves OIDC disabled when no OIDC variables are configured" do
    config = read_runtime_config()

    refute get_in(config, [:pinchflat, :oidc])
  end

  test "raises when any required OIDC variable is missing" do
    System.put_env("OIDC_ISSUER", "https://sso.example")
    System.put_env("OIDC_CLIENT_ID", "pinchyt")

    assert_raise RuntimeError, ~r/OIDC_CLIENT_SECRET/, fn ->
      read_runtime_config()
    end
  end

  test "raises when only an optional OIDC variable is configured" do
    System.put_env("OIDC_PROVIDER_NAME", "Authentik")

    assert_raise RuntimeError, ~r/OIDC_ISSUER.*OIDC_CLIENT_ID.*OIDC_CLIENT_SECRET/s, fn ->
      read_runtime_config()
    end
  end

  test "configures OIDC when all required variables are present" do
    System.put_env("OIDC_ISSUER", "https://sso.example")
    System.put_env("OIDC_CLIENT_ID", "pinchyt")
    System.put_env("OIDC_CLIENT_SECRET", "secret")

    oidc_config = read_runtime_config() |> get_in([:pinchflat, :oidc])

    assert oidc_config[:issuer] == "https://sso.example"
    assert oidc_config[:client_id] == "pinchyt"
    assert oidc_config[:client_secret] == "secret"
  end

  defp read_runtime_config do
    Config.Reader.read!("config/runtime.exs", env: :test)
  end
end
