defmodule Pinchflat.RetentionRuntimeConfigTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Pinchflat.Downloading.MediaRetentionWorker

  @env_vars ~w(RETENTION_CRON RETENTION_TIMEZONE TZ)

  setup do
    previous_values = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "defaults to daily retention at 01:00 UTC" do
    assert retention_entry() == {"0 1 * * *", MediaRetentionWorker, timezone: "Etc/UTC"}
    assert :ok = Oban.Cron.validate(cron_config())
  end

  test "uses the configured cron and retention timezone only for retention" do
    original_entries = other_entries()

    System.put_env("RETENTION_CRON", "0 */4 * * *")
    System.put_env("RETENTION_TIMEZONE", "Europe/Berlin")
    System.put_env("TZ", "America/New_York")

    assert retention_entry() == {"0 */4 * * *", MediaRetentionWorker, timezone: "Europe/Berlin"}
    assert other_entries() == original_entries
    assert :ok = Oban.Cron.validate(cron_config())
  end

  test "keeps the default UTC schedule when only TZ is configured" do
    System.put_env("TZ", "Europe/Berlin")

    assert retention_entry() == {"0 1 * * *", MediaRetentionWorker, timezone: "Etc/UTC"}
  end

  test "uses the retention timezone with the default schedule" do
    System.put_env("RETENTION_TIMEZONE", "Europe/Berlin")

    assert retention_entry() == {"0 1 * * *", MediaRetentionWorker, timezone: "Europe/Berlin"}
  end

  test "uses UTC with a custom schedule regardless of TZ" do
    System.put_env("RETENTION_CRON", "0 */4 * * *")
    System.put_env("TZ", "Europe/Berlin")

    assert retention_entry() == {"0 */4 * * *", MediaRetentionWorker, timezone: "Etc/UTC"}
  end

  test "rejects invalid and empty cron expressions" do
    for value <- ["", "not a cron", "60 * * * *"] do
      System.put_env("RETENTION_CRON", value)
      assert {:error, _reason} = Oban.Cron.validate(cron_config())
    end
  end

  test "rejects invalid and empty timezones" do
    for value <- ["", "Invalid/Timezone"] do
      System.put_env("RETENTION_TIMEZONE", value)
      assert {:error, _reason} = Oban.Cron.validate(cron_config())
    end
  end

  defp retention_entry do
    cron_config()
    |> Keyword.fetch!(:crontab)
    |> Enum.find(&(elem(&1, 1) == MediaRetentionWorker))
  end

  defp other_entries do
    cron_config()
    |> Keyword.fetch!(:crontab)
    |> Enum.reject(&(elem(&1, 1) == MediaRetentionWorker))
    |> Enum.map(fn
      {_boot_time_cron, Pinchflat.YtDlp.UpdateWorker} -> {:boot_time_cron, Pinchflat.YtDlp.UpdateWorker}
      entry -> entry
    end)
  end

  defp cron_config do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :test)
    |> get_in([:pinchflat, Oban, :plugins])
    |> Keyword.fetch!(Oban.Plugins.Cron)
  end
end
