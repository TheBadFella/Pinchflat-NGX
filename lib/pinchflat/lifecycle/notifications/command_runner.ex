defmodule Pinchflat.Lifecycle.Notifications.CommandRunner do
  @moduledoc """
  Runs apprise commands using the `System.cmd/3` function.
  Notification bodies use Apprise's default plain-text input format.
  """

  require Logger

  alias Pinchflat.Utils.CliUtils
  alias Pinchflat.Utils.FunctionUtils
  alias Pinchflat.Lifecycle.Notifications.AppriseCommandRunner

  @behaviour AppriseCommandRunner

  @doc """
  Runs an apprise command. Provider output is withheld because notification URLs
  and provider errors can contain credentials. Failures retain the CLI exit status.
  Can take a single server string or a list of servers as well as additional
  arguments to pass to the command.

  Returns {:ok, binary()} | {:error, :no_servers} | {:error, binary()}
  """
  @impl AppriseCommandRunner
  def run(nil, _), do: {:error, :no_servers}
  def run("", _), do: {:error, :no_servers}
  def run([], _), do: {:error, :no_servers}

  def run(endpoints, command_opts) do
    endpoints =
      endpoints
      |> List.wrap()
      |> Enum.map(&normalize_endpoint/1)

    default_opts = [:verbose]
    parsed_opts = CliUtils.parse_options(default_opts ++ command_opts)

    {output, exit_code} =
      CliUtils.wrap_cmd(backend_executable(), parsed_opts ++ endpoints, [],
        logging_arg_override: "[notification arguments withheld]",
        output_transform: fn _output -> "" end
      )

    case exit_code do
      0 -> {:ok, String.trim(output)}
      _ -> {:error, "Apprise exited with status #{exit_code}. Check the notification server configuration."}
    end
  end

  @doc """
  Normalizes an endpoint URL. Ensures Discord webhook URLs request markdown formatting
  so Apprise formats notifications as Discord embeds.
  """
  def normalize_endpoint(endpoint) when is_binary(endpoint) do
    if discord_webhook?(endpoint) and not String.contains?(endpoint, "format=") do
      append_query_param(endpoint, "format", "markdown")
    else
      endpoint
    end
  end

  def normalize_endpoint(endpoint), do: endpoint

  defp discord_webhook?(endpoint) do
    String.starts_with?(endpoint, "discord://") or
      String.contains?(endpoint, "discord.com/api/webhooks/") or
      String.contains?(endpoint, "discordapp.com/api/webhooks/")
  end

  defp append_query_param(url, key, value) do
    delimiter = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{delimiter}#{key}=#{value}"
  end

  @doc """
  Returns the version of apprise as a string.

  Returns {:ok, binary()} | {:error, binary()}
  """
  @impl AppriseCommandRunner
  def version do
    case CliUtils.wrap_cmd(backend_executable(), ["--version"]) do
      {output, 0} ->
        output
        |> String.split(~r{\r?\n})
        |> List.first()
        |> String.replace("Apprise", "")
        |> String.trim()
        |> FunctionUtils.wrap_ok()

      {output, _} ->
        {:error, output}
    end
  end

  defp backend_executable do
    Application.get_env(:pinchflat, :apprise_executable)
  end
end
