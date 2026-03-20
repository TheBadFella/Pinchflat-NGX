defmodule Pinchflat.YtDlp.CommandRunner do
  @moduledoc """
  Runs yt-dlp commands using the `System.cmd/3` function
  """

  require Logger

  alias Pinchflat.Settings
  alias Pinchflat.Utils.CliUtils
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.YtDlp.YtDlpCommandRunner
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @behaviour YtDlpCommandRunner

  @doc """
  Runs a yt-dlp command and returns the string output. Saves the output to
  a file and then returns its contents because yt-dlp will return warnings
  to stdout even if the command is successful, but these will break JSON parsing.

  Additional Opts:
    - :output_filepath - the path to save the output to. If not provided, a temporary
      file will be created and used. Useful for if you need a reference to the file
      for a file watcher.
    - :use_cookies - if true, will add a cookie file to the command options. Will not
      attach a cookie file if the user hasn't set one up.
    - :skip_sleep_interval - if true, will not add the sleep interval options to the command.
      Usually only used for commands that would be UI-blocking

  Returns {:ok, binary()} | {:error, output, status}.
  """
  @impl YtDlpCommandRunner
  def run(url, action_name, command_opts, output_template, addl_opts \\ []) do
    Logger.debug("Running yt-dlp command for action: #{action_name}")

    output_filepath = generate_output_filepath(addl_opts)
    print_to_file_opts = [{:print_to_file, output_template}, output_filepath]

    user_configured_opts =
      cookie_file_options(addl_opts) ++
        rate_limit_options(addl_opts) ++
        misc_options() ++
        progress_options(addl_opts)

    # These must stay in exactly this order, hence why I'm giving it its own variable.
    all_opts = command_opts ++ print_to_file_opts ++ user_configured_opts ++ global_options(addl_opts)
    formatted_command_opts = [url] ++ CliUtils.parse_options(all_opts)

    command_result =
      if action_name == :download && Keyword.has_key?(addl_opts, :progress_handler) do
        wrap_streaming_cmd(backend_executable(), formatted_command_opts, addl_opts)
      else
        CliUtils.wrap_cmd(backend_executable(), formatted_command_opts, stderr_to_stdout: true)
      end

    case command_result do
      # yt-dlp exit codes:
      #   0 = Everything is successful
      #   100 = yt-dlp must restart for update to complete
      #   101 = Download cancelled by --max-downloads etc
      #     2 = Error in user-provided options
      #     1 = Any other error
      {_, status} when status in [0, 101] ->
        File.read(output_filepath)

      {output, status} ->
        {:error, output, status}
    end
  end

  @doc """
  Returns the version of yt-dlp as a string

  Returns {:ok, binary()} | {:error, binary()}
  """
  @impl YtDlpCommandRunner
  def version do
    command = backend_executable()

    case CliUtils.wrap_cmd(command, ["--version"]) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _} ->
        {:error, output}
    end
  end

  @doc """
  Updates yt-dlp to the latest version

  Returns {:ok, binary()} | {:error, binary()}
  """
  @impl YtDlpCommandRunner
  def update do
    command = backend_executable()

    case CliUtils.wrap_cmd(command, ["--update-to", "nightly"]) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _} ->
        {:error, output}
    end
  end

  defp generate_output_filepath(addl_opts) do
    case Keyword.get(addl_opts, :output_filepath) do
      nil -> FSUtils.generate_metadata_tmpfile(:json)
      path -> path
    end
  end

  defp global_options(addl_opts) do
    quiet_opt = if Keyword.has_key?(addl_opts, :progress_handler), do: [], else: [:quiet]

    [
      :windows_filenames,
      cache_dir: Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "yt-dlp-cache")
    ] ++ quiet_opt
  end

  defp cookie_file_options(addl_opts) do
    case Keyword.get(addl_opts, :use_cookies) do
      true -> add_cookie_file()
      _ -> []
    end
  end

  defp add_cookie_file do
    base_dir = Application.get_env(:pinchflat, :extras_directory)
    filename_options_map = %{cookies: "cookies.txt"}

    Enum.reduce(filename_options_map, [], fn {opt_name, filename}, acc ->
      filepath = Path.join(base_dir, filename)

      if FSUtils.exists_and_nonempty?(filepath) do
        [{opt_name, filepath} | acc]
      else
        acc
      end
    end)
  end

  defp rate_limit_options(addl_opts) do
    throughput_limit = Settings.get!(:download_throughput_limit)
    sleep_interval_opts = sleep_interval_opts(addl_opts)
    throughput_option = if throughput_limit, do: [limit_rate: throughput_limit], else: []

    throughput_option ++ sleep_interval_opts
  end

  defp sleep_interval_opts(addl_opts) do
    sleep_interval = Settings.get!(:extractor_sleep_interval_seconds)

    if sleep_interval <= 0 || Keyword.get(addl_opts, :skip_sleep_interval) do
      []
    else
      [
        sleep_requests: NumberUtils.add_jitter(sleep_interval),
        sleep_interval: NumberUtils.add_jitter(sleep_interval),
        sleep_subtitles: NumberUtils.add_jitter(sleep_interval)
      ]
    end
  end

  defp misc_options do
    if Settings.get!(:restrict_filenames), do: [:restrict_filenames], else: []
  end

  defp progress_options(addl_opts) do
    if Keyword.has_key?(addl_opts, :progress_handler) do
      [
        :newline,
        progress_template:
          "download:pinchflat-progress:%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s|%(progress.speed)s"
      ]
    else
      []
    end
  end

  defp wrap_streaming_cmd(command, args, addl_opts) do
    wrapper_command = Path.join(:code.priv_dir(:pinchflat), "cmd_wrapper.sh")
    actual_command = [command] ++ args
    logging_arg_override = Enum.join(args, " ")
    progress_handler = Keyword.fetch!(addl_opts, :progress_handler)

    Logger.info("[command_wrapper]: #{command} called with: #{logging_arg_override}")

    port =
      Port.open(
        {:spawn_executable, wrapper_command},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: actual_command,
          cd: Application.get_env(:pinchflat, :tmpfile_directory) |> String.to_charlist()
        ]
      )

    {output, status} = stream_port_output(port, progress_handler, "", "")
    log_cmd_result(command, logging_arg_override, status, output)

    {output, status}
  end

  defp stream_port_output(port, progress_handler, output_acc, line_buffer) do
    receive do
      {^port, {:data, data}} ->
        {next_buffer, progress_updates} = extract_progress_updates(line_buffer <> data, [])

        Enum.each(progress_updates, progress_handler)

        stream_port_output(port, progress_handler, output_acc <> data, next_buffer)

      {^port, {:exit_status, status}} ->
        Enum.each(finalize_progress_buffer(line_buffer), progress_handler)
        {output_acc, status}
    end
  end

  defp extract_progress_updates(buffer, acc) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        progress_update =
          line
          |> String.trim()
          |> parse_progress_line()

        extract_progress_updates(rest, maybe_append_progress(acc, progress_update))

      [_partial] ->
        {buffer, Enum.reverse(acc)}
    end
  end

  defp finalize_progress_buffer(""), do: []

  defp finalize_progress_buffer(buffer) do
    case parse_progress_line(String.trim(buffer)) do
      nil -> []
      progress_update -> [progress_update]
    end
  end

  defp maybe_append_progress(acc, nil), do: acc
  defp maybe_append_progress(acc, progress_update), do: [progress_update | acc]

  defp parse_progress_line("pinchflat-progress:" <> progress_payload) do
    case String.split(progress_payload, "|") do
      [percent, _downloaded_bytes, _total_bytes, _estimated_total_bytes, _eta, _speed] ->
        %{
          progress_percent: parse_percent(percent),
          progress_status: "Downloading"
        }

      _ ->
        nil
    end
  end

  defp parse_progress_line(_line), do: nil

  defp parse_percent(percent) do
    percent
    |> String.replace("%", "")
    |> String.trim()
    |> Float.parse()
    |> case do
      {parsed, _rest} -> min(parsed, 100.0)
      :error -> nil
    end
  end

  defp log_cmd_result(command, logging_arg_override, status, output) do
    log_message = "[command_wrapper]: #{command} called with: #{logging_arg_override} exited: #{status} with: #{output}"
    log_level = if status == 0, do: :debug, else: :error

    Logger.log(log_level, log_message)
  end

  defp backend_executable do
    Application.get_env(:pinchflat, :yt_dlp_executable)
  end
end
