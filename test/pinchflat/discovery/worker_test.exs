defmodule Pinchflat.Discovery.WorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.Suggestion
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

    test "a manual scan saves a mentioned channel from successful yt-dlp output" do
      Settings.set(channel_discovery_mentions_enabled: true)
      Settings.set(channel_discovery_featured_enabled: false)
      source_fixture(%{description: "See https://www.youtube.com/@discoveryexample for more."})
      channel_id = "UC" <> String.duplicate("a", 22)
      canonical_url = "https://www.youtube.com/channel/#{channel_id}"

      expect(YtDlpRunnerMock, :run, fn "https://www.youtube.com/@discoveryexample",
                                       :channel_discovery_validate,
                                       _command_opts,
                                       _output_template,
                                       _additional_opts ->
        {:ok, Jason.encode!(%{channel_id: channel_id, channel: "Discovery Example"})}
      end)

      assert {:ok, %Oban.Job{args: args}} = Worker.kickoff()
      assert :ok = perform_job(Worker, args)

      assert [
               %Suggestion{
                 external_channel_id: ^channel_id,
                 canonical_url: ^canonical_url,
                 channel_name: "Discovery Example",
                 state: :validated
               }
             ] = Discovery.list_suggestions()
    end
  end
end
