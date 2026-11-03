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
