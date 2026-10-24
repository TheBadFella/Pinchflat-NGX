defmodule Pinchflat.JobRecoveryConfigTest do
  use ExUnit.Case, async: false

  test "runtime configuration does not recover jobs solely because they have been running a long time" do
    config = Config.Reader.read!("config/runtime.exs", env: :test)[:pinchflat][Oban]
    assert :ok = Oban.Config.validate(config)

    config = Oban.Config.new(Keyword.put(config, :testing, :disabled))

    plugins =
      Enum.map(config.plugins, fn
        {module, _opts} -> module
        module -> module
      end)

    refute Oban.Lifeline in plugins
    refute Oban.Plugins.Lifeline in plugins
  end
end
