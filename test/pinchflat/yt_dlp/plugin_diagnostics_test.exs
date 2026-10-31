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
        :ok
      end)

      with_debug_logs(fn ->
        capture_log(fn ->
          PluginDiagnostics.report(@output, 0, :download)
          PluginDiagnostics.report(@output, 0, :download)
        end)
      end)
    end

    test "does not alert without an apprise server" do
      expect(AppriseRunnerMock, :run, 0, fn _servers, _opts -> flunk("unexpected alert") end)
      with_debug_logs(fn -> capture_log(fn -> PluginDiagnostics.report(@output, 0, :download) end) end)
    end

    test "reports different plugin failures separately" do
      Settings.set(apprise_server: "json://localhost")
      other_output = String.replace(@output, "danmaku", "other")

      expect(AppriseRunnerMock, :run, 2, fn _servers, _opts -> :ok end)

      with_debug_logs(fn ->
        capture_log(fn ->
          PluginDiagnostics.report(@output, 0, :download)
          PluginDiagnostics.report(other_output, 0, :download)
        end)
      end)
    end
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
