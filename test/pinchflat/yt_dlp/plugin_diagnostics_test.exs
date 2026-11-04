defmodule Pinchflat.YtDlp.PluginDiagnosticsTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.PluginDiagnostics

  @output """
  [debug] Command-line config: ['--plugin-dirs', '/tmp/plugins']
  Error while importing module 'yt_dlp_plugins.postprocessor.danmaku'
  Traceback (most recent call last):
    File "/tmp/plugins/yt-dlp-danmaku.zip/yt_dlp_plugins/postprocessor/danmaku.py", line 2
      from yt_dlp_danmaku import YoutubeDLDanmaku
  ModuleNotFoundError: No module named 'yt_dlp_danmaku'
  """

  setup do
    PluginDiagnostics.reset_alert_state()
    Settings.set(apprise_server: nil)

    on_exit(fn -> PluginDiagnostics.reset_alert_state() end)

    :ok
  end

  describe "extract_issues/1" do
    test "extracts plugin import failures" do
      assert [%{module: "yt_dlp_plugins.postprocessor.danmaku", detail: detail}] =
               PluginDiagnostics.extract_issues(@output)

      assert detail =~ "ModuleNotFoundError"
    end

    test "ignores benign output" do
      assert PluginDiagnostics.extract_issues("[debug] Loaded 1747 extractors") == []
    end
  end

  describe "report/3" do
    test "logs plugin failures at error level" do
      log =
        with_debug_logs(fn ->
          capture_log(fn -> PluginDiagnostics.report(@output, 0, :download) end)
        end)

      assert log =~ "[yt-dlp plugins]"
      assert log =~ "yt_dlp_plugins.postprocessor.danmaku"
    end

    test "sends an apprise alert once per signature" do
      Settings.set(apprise_server: "json://localhost")

      expect(AppriseRunnerMock, :run, 1, fn servers, opts ->
        assert servers == ["json://localhost"]
        assert opts[:notification_type] == "failure"
        assert opts[:title] =~ "yt-dlp plugin issue"
        assert opts[:body] =~ "yt_dlp_plugins.postprocessor.danmaku"
        {:ok, ""}
      end)

      log =
        report_with_logs(fn ->
          assert :ok = PluginDiagnostics.report(@output, 0, :download)
          assert :ok = PluginDiagnostics.report(@output, 0, :download)
        end)

      assert log =~ "Sent plugin failure alert"
    end

    test "does not alert without an apprise server" do
      # No expectation is registered, so any runner call would raise inside report/3.
      # report/3 swallows raises, which report_with_logs/1 turns back into a failure.
      report_with_logs(fn -> assert :ok = PluginDiagnostics.report(@output, 0, :download) end)
    end

    test "reports different plugin failures separately" do
      Settings.set(apprise_server: "json://localhost")
      other_output = String.replace(@output, "danmaku", "other")

      expect(AppriseRunnerMock, :run, 2, fn _servers, _opts -> {:ok, ""} end)

      report_with_logs(fn ->
        PluginDiagnostics.report(@output, 0, :download)
        PluginDiagnostics.report(other_output, 0, :download)
      end)
    end

    test "retries the alert on the next report when the runner fails" do
      Settings.set(apprise_server: "json://localhost")

      expect(AppriseRunnerMock, :run, 2, fn _servers, _opts -> {:error, "Apprise exited with status 1"} end)

      log =
        report_with_logs(fn ->
          PluginDiagnostics.report(@output, 0, :download)
          PluginDiagnostics.report(@output, 0, :download)
        end)

      assert log =~ "Failed to send plugin failure alert"
    end

    test "logs and returns :ok when diagnostics themselves raise" do
      Settings.set(apprise_server: "json://localhost")

      expect(AppriseRunnerMock, :run, 1, fn _servers, _opts -> raise "runner exploded" end)

      log =
        with_debug_logs(fn ->
          capture_log(fn -> assert :ok = PluginDiagnostics.report(@output, 0, :download) end)
        end)

      assert log =~ "Plugin diagnostics failed: runner exploded"
    end
  end

  describe "report/3 under concurrency" do
    # The runner is called from the task processes, so the mock must answer in any process.
    setup :set_mox_global

    setup do
      Settings.set(apprise_server: "json://localhost")
      {:ok, calls: :counters.new(1, [])}
    end

    test "sends one alert when concurrent jobs report the same failure", %{calls: calls} do
      stub(AppriseRunnerMock, :run, fn _servers, _opts ->
        :counters.add(calls, 1, 1)
        # Long enough that every concurrent caller has passed its cooldown check before this returns.
        Process.sleep(150)
        {:ok, ""}
      end)

      report_with_logs(fn -> report_concurrently(@output, 4) end)

      assert :counters.get(calls, 1) == 1

      # The cooldown now covers it, so a later report stays quiet too.
      report_with_logs(fn -> PluginDiagnostics.report(@output, 0, :download) end)
      assert :counters.get(calls, 1) == 1
    end

    test "alerts once per distinct failure when different failures report concurrently", %{calls: calls} do
      other_output = String.replace(@output, "danmaku", "other")

      stub(AppriseRunnerMock, :run, fn _servers, _opts ->
        :counters.add(calls, 1, 1)
        Process.sleep(150)
        {:ok, ""}
      end)

      report_with_logs(fn ->
        [@output, other_output, @output, other_output]
        |> Enum.map(fn output -> Task.async(fn -> PluginDiagnostics.report(output, 0, :download) end) end)
        |> Enum.each(&Task.await(&1, 5_000))
      end)

      assert :counters.get(calls, 1) == 2
    end

    test "does not make other jobs wait while a notification is being sent", %{calls: calls} do
      test_pid = self()

      stub(AppriseRunnerMock, :run, fn _servers, _opts ->
        :counters.add(calls, 1, 1)
        send(test_pid, {:sending, self()})

        receive do
          :finish -> {:ok, ""}
        end
      end)

      slow_job = Task.async(fn -> PluginDiagnostics.report(@output, 0, :download) end)
      assert_receive {:sending, sender}, 2_000

      # Another job hitting the same failure returns promptly while the first alert is still in flight.
      other_job = Task.async(fn -> PluginDiagnostics.report(@output, 0, :download) end)
      assert {:ok, :ok} = Task.yield(other_job, 1_000)

      send(sender, :finish)
      assert :ok = Task.await(slow_job, 5_000)
      assert :counters.get(calls, 1) == 1
    end

    test "keeps a failed concurrent alert retryable", %{calls: calls} do
      stub(AppriseRunnerMock, :run, fn _servers, _opts ->
        attempt = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)

        if attempt == 0 do
          Process.sleep(150)
          {:error, "Apprise exited with status 1"}
        else
          {:ok, ""}
        end
      end)

      report_with_logs(fn -> report_concurrently(@output, 4) end)
      assert :counters.get(calls, 1) == 1

      # The failed claim was given back, so the next report sends again and then the cooldown holds.
      report_with_logs(fn -> PluginDiagnostics.report(@output, 0, :download) end)
      assert :counters.get(calls, 1) == 2

      report_with_logs(fn -> PluginDiagnostics.report(@output, 0, :download) end)
      assert :counters.get(calls, 1) == 2
    end

    test "gives the claim back when the runner raises", %{calls: calls} do
      stub(AppriseRunnerMock, :run, fn _servers, _opts ->
        attempt = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)
        if attempt == 0, do: raise("runner exploded"), else: {:ok, ""}
      end)

      log =
        with_debug_logs(fn ->
          capture_log(fn ->
            assert :ok = PluginDiagnostics.report(@output, 0, :download)
            assert :ok = PluginDiagnostics.report(@output, 0, :download)
          end)
        end)

      assert log =~ "Plugin diagnostics failed: runner exploded"
      assert :counters.get(calls, 1) == 2
    end
  end

  # Releases the callers together so their cooldown checks genuinely overlap.
  defp report_concurrently(output, count) do
    parent = self()

    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> PluginDiagnostics.report(output, 0, :download)
          end
        end)
      end

    ready =
      for _ <- 1..count do
        assert_receive {:ready, pid}, 2_000
        pid
      end

    Enum.each(ready, &send(&1, :go))
    Enum.each(tasks, &Task.await(&1, 5_000))
  end

  # Runs fun with debug logging, asserting that report/3 did not have to swallow a raise
  # (which would otherwise hide failed assertions and unexpected Mox calls) and returning the log.
  defp report_with_logs(fun) do
    log = with_debug_logs(fn -> capture_log(fun) end)
    refute log =~ "Plugin diagnostics failed"
    log
  end

  defp with_debug_logs(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end
end
