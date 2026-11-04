defmodule Pinchflat.YtDlp.PluginAlertCooldownTest do
  use ExUnit.Case, async: false

  alias Pinchflat.YtDlp.PluginAlertCooldown

  setup do
    PluginAlertCooldown.reset()
    on_exit(&PluginAlertCooldown.reset/0)
    :ok
  end

  describe "claim/3" do
    test "claims an alert that has not been sent" do
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:failure, 1_000, 3_600)
    end

    test "refuses a second claim inside the cooldown" do
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:failure, 1_000, 3_600)
      assert :cooling_down = PluginAlertCooldown.claim(:failure, 1_001, 3_600)
      assert :cooling_down = PluginAlertCooldown.claim(:failure, 4_599, 3_600)
    end

    test "allows a claim again once the cooldown has passed" do
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:failure, 1_000, 3_600)
      assert {:claimed, 4_600} = PluginAlertCooldown.claim(:failure, 4_600, 3_600)
    end

    test "tracks different signatures separately" do
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:one, 1_000, 3_600)
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:two, 1_000, 3_600)
    end

    test "grants exactly one of many simultaneous claims" do
      results =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> PluginAlertCooldown.claim(:failure, 1_000, 3_600) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:claimed, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :cooling_down)) == 49
    end
  end

  describe "release/2" do
    test "makes the failure claimable again" do
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:failure, 1_000, 3_600)
      assert :ok = PluginAlertCooldown.release(:failure, 1_000)
      assert {:claimed, 1_001} = PluginAlertCooldown.claim(:failure, 1_001, 3_600)
    end

    test "leaves a newer claim for the same signature in place" do
      assert {:claimed, 1_000} = PluginAlertCooldown.claim(:failure, 1_000, 3_600)
      assert {:claimed, 4_600} = PluginAlertCooldown.claim(:failure, 4_600, 3_600)

      assert :ok = PluginAlertCooldown.release(:failure, 1_000)
      assert :cooling_down = PluginAlertCooldown.claim(:failure, 4_601, 3_600)
    end

    test "ignores a signature that was never claimed" do
      assert :ok = PluginAlertCooldown.release(:unknown, 1_000)
    end
  end
end
