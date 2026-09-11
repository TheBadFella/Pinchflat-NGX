defmodule Pinchflat.Discovery.WorkerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.Worker
  alias Pinchflat.Settings

  describe "kickoff/0" do
    test "deduplicates manual scans across repeated kickoffs" do
      assert {:ok, %Oban.Job{}} = Worker.kickoff()
      assert {:error, :duplicate_job} = Worker.kickoff()
      assert [_job] = all_enqueued(worker: Worker)
    end
  end

  describe "perform/1 scheduled gate" do
    test "is registered daily and cancels safely while disabled" do
      plugins = Application.get_env(:pinchflat, Oban)[:plugins]
      assert {Oban.Plugins.Cron, [crontab: crontab]} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))
      assert {"0 3 * * *", Worker} in crontab

      Settings.set(channel_discovery_enabled: false)
      Discovery.subscribe()

      assert {:cancel, "Scheduled channel discovery is disabled"} = perform_job(Worker, %{})

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "channel_discovery",
        event: "scan_completed",
        payload: %{status: :disabled}
      }
    end

    test "manual scans are allowed through the scheduled gate" do
      Settings.set(channel_discovery_enabled: false)

      assert :ok = perform_job(Worker, %{"manual" => true})
    end
  end
end
