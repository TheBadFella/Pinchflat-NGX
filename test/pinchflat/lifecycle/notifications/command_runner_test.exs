defmodule Pinchflat.Lifecycle.Notifications.CommandRunnerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Lifecycle.Notifications.CommandRunner, as: Runner

  @original_executable Application.compile_env(:pinchflat, :apprise_executable)

  setup do
    on_exit(&reset_executable/0)
  end

  describe "run/2" do
    test "does not expose notification credentials in command logs or returned output" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)

      try do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            assert {:ok, output} = Runner.run("json://lab:SECRET_APPRISE184@receiver.invalid/SECRET_APPRISE184", [])
            refute output =~ "SECRET_APPRISE184"
          end)

        assert log =~ "command_wrapper"
        refute log =~ "SECRET_APPRISE184"
      after
        Logger.configure(level: previous_level)
      end
    end

    test "provider failures cannot expose credentials in returned errors or logs" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)

      try do
        record_arguments(
          fn ->
            log =
              ExUnit.CaptureLog.capture_log([level: :debug], fn ->
                assert {:error, error} =
                         Runner.run("json://lab:SECRET_APPRISE184@receiver.invalid/SECRET_APPRISE184", [])

                assert error =~ "status 2"
                refute error =~ "SECRET_APPRISE184"
              end)

            assert log =~ "exited: 2"
            refute log =~ "SECRET_APPRISE184"
          end,
          2
        )
      after
        Logger.configure(level: previous_level)
      end
    end

    test "returns :ok when the command succeeds" do
      assert {:ok, _} = Runner.run("server_1", [])
    end

    test "forwards servers and command arguments without exposing provider output" do
      args =
        record_arguments(fn ->
          assert {:ok, ""} = Runner.run(["server_1", "server_2"], ["--dry-run"])
        end)

      assert args == ["--verbose", "--dry-run", "server_1", "server_2"]
    end

    test "lets you pass a single server as a string" do
      assert record_arguments(fn -> assert {:ok, ""} = Runner.run("server_1", []) end) == ["--verbose", "server_1"]
    end

    test "passes unmatched Markdown delimiters literally using the default plain-text format" do
      body = "*unmatched _underscore [link]( `code <tag> & text"

      args = record_arguments(fn -> assert {:ok, ""} = Runner.run("server_1", body: body) end)

      assert args == ["--verbose", "--body", body, "server_1"]
    end

    test "returns the exit status when the command fails" do
      wrap_executable("/bin/false", fn ->
        assert {:error, "Apprise exited with status 1. Check the notification server configuration."} =
                 Runner.run("server_1", [])
      end)
    end

    test "returns a relevant error if no servers are provided" do
      assert {:error, :no_servers} = Runner.run(nil, [])
      assert {:error, :no_servers} = Runner.run("", [])
      assert {:error, :no_servers} = Runner.run([], [])
    end
  end

  describe "version/0" do
    test "adds the version arg" do
      assert {:ok, output} = Runner.version()

      assert String.contains?(output, "--version")
    end
  end

  defp record_arguments(fun, exit_status \\ 0) do
    directory = Path.join(System.tmp_dir!(), "apprise-arguments-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    script = Path.join(directory, "record.sh")
    output = Path.join(directory, "arguments.txt")
    File.write!(script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{output}'\nprintf '%s\\n' \"$@\"\nexit #{exit_status}\n")
    File.chmod!(script, 0o700)

    try do
      wrap_executable(script, fun)
      output |> File.read!() |> String.split("\n", trim: true)
    after
      File.rm_rf!(directory)
    end
  end

  defp wrap_executable(new_executable, fun) do
    Application.put_env(:pinchflat, :apprise_executable, new_executable)
    fun.()
    reset_executable()
  end

  def reset_executable do
    Application.put_env(:pinchflat, :apprise_executable, @original_executable)
  end
end
