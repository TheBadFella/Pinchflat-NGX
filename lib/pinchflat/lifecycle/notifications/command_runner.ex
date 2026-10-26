defmodule Pinchflat.Lifecycle.Notifications.CommandRunner do
  @moduledoc """
  Runs apprise commands using the `System.cmd/3` function.
  Notification bodies use Apprise's default plain-text input format. Discord endpoints
  without an explicit format option request embed presentation.
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
  Adds markdown formatting to Discord endpoints unless a format option is already set,
  so Apprise presents those notifications as embeds.
  """
  def normalize_endpoint(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    if discord_webhook?(uri) and not format_specified?(uri.query) do
      query = Enum.join(Enum.reject([uri.query, "format=markdown"], &is_nil/1), "&")
      URI.to_string(%{uri | query: query})
    else
      endpoint
    end
  end

  def normalize_endpoint(endpoint), do: endpoint

  defp discord_webhook?(%URI{scheme: "discord"}), do: true

  defp discord_webhook?(%URI{scheme: "https", host: host, path: path}) do
    host in ["discord.com", "discordapp.com"] and is_binary(path) and
      String.starts_with?(path, "/api/webhooks/")
  end

  defp discord_webhook?(_), do: false

  defp format_specified?(nil), do: false

  defp format_specified?(query) do
    Enum.any?(URI.query_decoder(query), fn {key, _value} -> key == "format" end)
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
