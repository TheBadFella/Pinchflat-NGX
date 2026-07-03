defmodule Pinchflat.Utils.CliUtilsTest do
  use Pinchflat.DataCase

  import ExUnit.CaptureLog

  alias Pinchflat.Utils.CliUtils

  describe "wrap_cmd/3" do
    test "delegates to System.cmd/3" do
      assert {"output\n", 0} = CliUtils.wrap_cmd("echo", ["output"])
    end

    test "sets the current directory to the tmp dir" do
      assert {"/tmp/test/tmpfiles\n", 0} = CliUtils.wrap_cmd("pwd", [])
    end
  end

  describe "wrap_cmd/3 when logging results" do
    setup do
      # The test env logger level suppresses everything below :critical,
      # so it needs to be loosened for log output to be capturable
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)
    end

    test "logs non-zero exits at the error level by default" do
      log = capture_log([level: :error], fn -> CliUtils.wrap_cmd("false", []) end)

      assert log =~ "exited: 1"
    end

    test "logs expected exit codes at the debug level instead" do
      log =
        capture_log([level: :error], fn ->
          CliUtils.wrap_cmd("false", [], [], expected_exit_codes: [1])
        end)

      refute log =~ "exited: 1"
    end
  end

  describe "parse_options/1" do
    test "it converts symbol k-v arg keys to kebab case" do
      assert ["--buffer-size", "1024"] = CliUtils.parse_options(buffer_size: 1024)
    end

    test "it keeps string k-v arg keys untouched" do
      assert ["--under_score", "1024"] = CliUtils.parse_options({"--under_score", 1024})
    end

    test "it converts symbol arg keys to kebab case" do
      assert ["--ignore-errors"] = CliUtils.parse_options(:ignore_errors)
    end

    test "it keeps string arg keys untouched" do
      assert ["-v"] = CliUtils.parse_options("-v")
    end
  end
end
