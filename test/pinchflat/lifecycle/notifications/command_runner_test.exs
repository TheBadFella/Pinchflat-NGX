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

  describe "normalize_endpoint/1" do
    test "appends format=markdown to discord webhook URLs without query params" do
      assert Runner.normalize_endpoint("https://discord.com/api/webhooks/123/abc") ==
               "https://discord.com/api/webhooks/123/abc?format=markdown"

      assert Runner.normalize_endpoint("discord://123/abc") ==
               "discord://123/abc?format=markdown"
    end

    test "appends &format=markdown to discord webhook URLs with existing query params" do
      assert Runner.normalize_endpoint("https://discord.com/api/webhooks/123/abc?avatar=Yes") ==
               "https://discord.com/api/webhooks/123/abc?avatar=Yes&format=markdown"
    end

    test "preserves explicit format options and query values that only resemble one" do
      url = "https://discord.com/api/webhooks/123/abc?format=text"
      assert Runner.normalize_endpoint(url) == url

      url = "discord://123/abc?other_format=text&next=https://example.org/?format=text"
      assert Runner.normalize_endpoint(url) == url <> "&format=markdown"

      url = "https://discord.com/api/webhooks/123/abc?format=html#section"
      assert Runner.normalize_endpoint(url) == url
      assert Runner.normalize_endpoint("discord://123/abc#section") ==
               "discord://123/abc?format=markdown#section"
    end

    test "leaves other endpoints unchanged even when they mention a Discord webhook" do
      assert Runner.normalize_endpoint("pover://user@token") == "pover://user@token"

      for url <- [
            "https://notify.example.com/send?next=https://discord.com/api/webhooks/123/abc",
            "https://discord.com.evil.invalid/api/webhooks/123/abc",
            "https://discord.com/other?path=/api/webhooks/123/abc",
            "http://discord.com/api/webhooks/123/abc"
          ] do
        assert Runner.normalize_endpoint(url) == url
      end
    end

    test "forwards literal plain-text bodies to unrelated providers while formatting only Discord URLs" do
      body = "*unmatched _underscore [link]( `code <tag> & text"

      args =
        record_arguments(fn ->
          assert {:ok, ""} =
                   Runner.run(["json://receiver.invalid", "discord://123/abc"], body: body)
        end)

      assert args == ["--verbose", "--body", body, "json://receiver.invalid", "discord://123/abc?format=markdown"]
    end

    test "installed Apprise CLI sends embeds only for Discord endpoints" do
      endpoints = %{
        "discord" => "discord://123/abc",
        "discord_https" => "https://discord.com/api/webhooks/123/abc",
        "discordapp_https" => "https://discordapp.com/api/webhooks/123/abc",
        "plain" => "json://receiver.invalid",
        "explicit_text" => "https://discord.com/api/webhooks/123/abc?format=text"
      }

      cases =
        Map.new(endpoints, fn {name, endpoint} ->
          argv =
            record_arguments(fn ->
              assert {:ok, ""} = Runner.run(endpoint, title: "New media found", body: "*unmatched _underscore")
            end)

          {name, argv}
        end)

      apprise = System.find_executable("apprise") || raise "Installed Apprise CLI is required"
      [shebang | _] = apprise |> File.read!() |> String.split("\n", parts: 2)
      python = String.trim_leading(shebang, "#!")

      {output, 0} =
        System.cmd(python, ["test/support/scripts/apprise_discord_payload.py", Jason.encode!(cases)],
          stderr_to_stdout: true
        )

      assert output =~ "Installed Apprise CLI produced Discord embeds and plain text"
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
