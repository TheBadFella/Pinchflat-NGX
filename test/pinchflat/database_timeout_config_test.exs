defmodule Pinchflat.DatabaseTimeoutConfigTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @env_vars ~w(DATABASE_TIMEOUT_MS DATABASE_URL RUN_CONTEXT OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET
               OIDC_SCOPES OIDC_CLIENT_AUTH_METHOD OIDC_PROVIDER_NAME OIDC_REDIRECT_URI)

  setup do
    previous_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    previous_adapter = Application.fetch_env!(:pinchflat, :database_adapter)
    Enum.each(@env_vars, &System.delete_env/1)
    System.put_env("RUN_CONTEXT", "selfhosted")
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/pinchflat_timeout_test")

    on_exit(fn ->
      Application.put_env(:pinchflat, :database_adapter, previous_adapter)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "applies inclusive bounds and trimmed values to both production adapters" do
    for adapter <- [:sqlite, :postgres],
        {value, expected} <- [{"15000", 15_000}, {" 60000 ", 60_000}, {"300000", 300_000}] do
      System.put_env("DATABASE_TIMEOUT_MS", value)
      assert repo_config(adapter)[:timeout] == expected
    end
  end

  test "unset, malformed and out-of-range values leave the existing defaults alone" do
    for adapter <- [:sqlite, :postgres],
        value <- [nil, "", " ", "14999", "300001", "0", "-5", "abc", "60s", "60000ms", "60000.0"] do
      if value, do: System.put_env("DATABASE_TIMEOUT_MS", value), else: System.delete_env("DATABASE_TIMEOUT_MS")
      refute Keyword.has_key?(repo_config(adapter), :timeout)
    end
  end

  defp repo_config(adapter) do
    Application.put_env(:pinchflat, :database_adapter, adapter)

    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod)
    |> get_in([:pinchflat, Pinchflat.Repo])
  end
end
