defmodule Pinchflat.YtDlp.CommandRunner do
  @moduledoc """
  Runs yt-dlp commands using the `System.cmd/3` function
  """

  require Logger

  alias Pinchflat.CookieHealth
  alias Pinchflat.Settings
  alias Pinchflat.Utils.CliUtils
  alias Pinchflat.Utils.NumberUtils
  alias Pinchflat.YtDlp.YtDlpCommandRunner
  alias Pinchflat.YtDlp.PluginDiagnostics
  alias Pinchflat.YtDlp.PluginDirectory
  alias Pinchflat.YtDlp.PoTokenProvider
  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @behaviour YtDlpCommandRunner

  @default_qjs_executable "/usr/local/bin/qjs"

  # Stage markers tell us how far yt-dlp got when it exits without writing the
  # requested output. A video rejected by a metadata filter gets the pre_process
  # marker but never reaches after_filter, so no after_move JSON is written.
  @pre_filter_marker "pinchflat-pre-process"
  @post_filter_marker "pinchflat-after-filter"
  @filter_skip_message "yt-dlp skipped this media item because it did not match the configured download filters"

  @doc """
  Runs a yt-dlp command and returns the string output. Saves the output to
  a file and then returns its contents because yt-dlp will return warnings
  to stdout even if the command is successful, but these will break JSON parsing.

  Additional Opts:
    - :output_filepath - the path to save the output to. If not provided, a temporary
      file will be created and used. Useful for if you need a reference to the file
      for a file watcher.
    - :use_cookies - if true, will add a cookie file to the command options. Will not
      attach a cookie file if the user hasn't set one up. Each invocation uses a
      temporary snapshot so yt-dlp cannot overwrite the shared file.
    - :cookies_filepath - an isolated cookie snapshot supplied and cleaned up by the caller.
    - :skip_sleep_interval - if true, will not add the sleep interval options to the command.
      Usually only used for commands that would be UI-blocking
    - :expected_exit_codes - additional non-zero exit codes the caller treats as a
      normal outcome and handles itself. These (plus 101, which this runner already
      treats as success) get logged at debug instead of error.

  Returns {:ok, binary()} | {:skipped, binary()} | {:error, output, status}.

  `{:skipped, message}` means yt-dlp exited successfully but intentionally
  filtered out the media before downloading it (for example `--datebefore` or
  `--match-filter`), so no `after_move` output exists. It is not a successful
  download and it is not an I/O or metadata failure.
  """
  @impl YtDlpCommandRunner
  def run(url, action_name, command_opts, output_template, addl_opts \\ []) do
    if Keyword.get(addl_opts, :use_cookies, false) && !Keyword.has_key?(addl_opts, :cookies_filepath) do
      result =
        CookieHealth.with_cookie_snapshot(fn path ->
          do_run(url, action_name, command_opts, output_template, Keyword.put(addl_opts, :cookies_filepath, path))
        end)

      case result do
        {:error, :not_configured} -> do_run(url, action_name, command_opts, output_template, addl_opts)
        result -> result
      end
    else
      do_run(url, action_name, command_opts, output_template, addl_opts)
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
  Returns the QuickJS-NG executable yt-dlp uses to solve JavaScript challenges.
  """
  def qjs_executable do
    Application.get_env(:pinchflat, :qjs_executable) || @default_qjs_executable
  end

  @doc """
  Returns typed yt-dlp options that pin the packaged QuickJS runtime.

  These are appended after user config locations so a scoped options file
  cannot silently select an unavailable runtime or disable JavaScript solving.
  """
  def js_runtime_options do
    [:no_js_runtimes, js_runtimes: "quickjs:#{qjs_executable()}"]
  end

  @doc """
  Returns the same runtime selection as raw argv strings for callers that build
  their own argument list, such as the YouTube browse provider.
  """
  def js_runtime_args do
    CliUtils.parse_options(js_runtime_options())
  end

  @doc """
  Updates yt-dlp to the given target.

  The target can be:
    - "stable" - updates to the latest stable release
    - "nightly" - updates to the latest nightly build
    - "nightly@2025.12.08.123456" - pins to that exact nightly build
    - a specific version like "2025.12.08" - pins to that exact stable release

  Returns {:ok, binary()} | {:error, binary()}
  """
  @impl YtDlpCommandRunner
  def update(target) do
    command = backend_executable()
    candidate = "#{command}.update-#{Ecto.UUID.generate()}"

    try do
      with :ok <- File.cp(command, candidate),
           :ok <- File.chmod(candidate, 0o755),
           {:ok, output} <- update_candidate(candidate, target),
           :ok <- validate_update_candidate(candidate),
           :ok <- File.rename(candidate, command) do
        {:ok, output}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "yt-dlp update failed: #{inspect(reason)}"}
      end
    after
      File.rm(candidate)
    end
  end

  defp do_run(url, action_name, command_opts, output_template, addl_opts) do
    Logger.debug("Running yt-dlp command for action: #{action_name}")

    output_filepath = generate_output_filepath(addl_opts)
    marker_filepath = stage_marker_filepath(action_name, output_filepath)
    print_to_file_opts = [{:print_to_file, output_template}, output_filepath] ++ stage_marker_options(marker_filepath)

    user_configured_opts =
      cookie_file_options(addl_opts) ++
        rate_limit_options(addl_opts) ++
        misc_options() ++
        progress_options(addl_opts)

    # These must stay in exactly this order, hence why I'm giving it its own variable.
    all_opts = command_opts ++ print_to_file_opts ++ user_configured_opts ++ global_options(addl_opts)
    formatted_command_opts = [url] ++ CliUtils.parse_options(all_opts)
    expected_exit_codes = [101] ++ Keyword.get(addl_opts, :expected_exit_codes, [])

    wrap_cmd_opts =
      [expected_exit_codes: expected_exit_codes] ++ Keyword.take(addl_opts, [:logging_arg_override, :output_transform])

    maybe_remove(marker_filepath)

    command_result =
      if action_name == :download && Keyword.has_key?(addl_opts, :progress_handler) do
        wrap_streaming_cmd(backend_executable(), formatted_command_opts, addl_opts)
      else
        CliUtils.wrap_cmd(backend_executable(), formatted_command_opts, [stderr_to_stdout: true], wrap_cmd_opts)
      end

    {command_output, status} = command_result
    PluginDiagnostics.report(command_output, status, action_name)

    case command_result do
      # yt-dlp exit codes:
      #   0 = Everything is successful
      #   100 = yt-dlp must restart for update to complete
      #   101 = Download cancelled by --max-downloads etc
      #     2 = Error in user-provided options
      #     1 = Any other error
      {command_output, 0} ->
        read_download_output(output_filepath, marker_filepath, command_output)

      {_, status} when status == 101 ->
        maybe_remove(marker_filepath)
        File.read(output_filepath)

      {output, status} ->
        maybe_remove(marker_filepath)
        {:error, output, status}
    end
  end

  defp update_candidate(candidate, target) do
    case retry_self_update(candidate, target) do
      {:ok, output} -> {:ok, output}
      {:error, output} -> maybe_fallback_to_direct_download(candidate, output, target)
    end
  end

  defp build_update_args("stable"), do: ["--update"]
  defp build_update_args("nightly"), do: ["--update-to", "nightly"]
  # `nightly` is yt-dlp's channel alias for the yt-dlp/yt-dlp-nightly-builds repo;
  # `<channel>@<tag>` pins to an exact build. Naming the repo directly (e.g.
  # `yt-dlp/yt-dlp_nightly@<tag>`) fails because that repo doesn't exist.
  defp build_update_args("nightly@" <> version), do: ["--update-to", "nightly@#{version}"]
  defp build_update_args(version), do: ["--update-to", "yt-dlp/yt-dlp@#{version}"]

  defp generate_output_filepath(addl_opts) do
    case Keyword.get(addl_opts, :output_filepath) do
      nil -> FSUtils.generate_metadata_tmpfile(:json)
      path -> path
    end
  end

  defp stage_marker_filepath(:download, output_filepath), do: output_filepath <> ".stages"
  defp stage_marker_filepath(_action, _output_filepath), do: nil

  defp stage_marker_options(nil), do: []

  defp stage_marker_options(marker_filepath) do
    [
      {:print_to_file, "pre_process:#{@pre_filter_marker}"},
      marker_filepath,
      {:print_to_file, "after_filter:#{@post_filter_marker}"},
      marker_filepath
    ]
  end

  defp read_download_output(output_filepath, marker_filepath, command_output) do
    result = File.read(output_filepath)
    skipped? = filtered_out?(result, marker_filepath)

    maybe_remove(marker_filepath)

    if skipped?, do: {:skipped, filter_skip_message(command_output)}, else: result
  end

  # A successful exit with no after_move output is only a filter skip when
  # yt-dlp started processing the video (pre_process) but never passed the
  # metadata filters (after_filter). An empty output after after_filter ran is
  # still a genuine failure, and a missing output file stays an I/O error.
  defp filtered_out?({:ok, output}, marker_filepath) do
    String.trim(output) == "" and filter_rejected?(marker_filepath)
  end

  defp filtered_out?(_result, _marker_filepath), do: false

  defp filter_rejected?(nil), do: false

  defp filter_rejected?(marker_filepath) do
    case File.read(marker_filepath) do
      {:ok, stages} ->
        String.contains?(stages, @pre_filter_marker) and not String.contains?(stages, @post_filter_marker)

      _ ->
        false
    end
  end

  defp filter_skip_message(command_output) do
    reason =
      command_output
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(&1, "[download] "))

    case reason do
      nil -> @filter_skip_message
      line -> @filter_skip_message <> ": " <> String.trim_leading(line, "[download] ")
    end
  end

  defp maybe_remove(nil), do: :ok
  defp maybe_remove(filepath), do: File.rm(filepath)

  defp global_options(addl_opts) do
    quiet_opt = if Keyword.has_key?(addl_opts, :progress_handler), do: [], else: [:quiet]

    [
      :windows_filenames,
      cache_dir: Path.join(Application.get_env(:pinchflat, :tmpfile_directory), "yt-dlp-cache")
    ] ++
      quiet_opt ++
      PoTokenProvider.plugin_options() ++
      PluginDirectory.options() ++ PluginDirectory.config_locations() ++ js_runtime_options()
  end

  defp cookie_file_options(addl_opts) do
    case Keyword.get(addl_opts, :cookies_filepath) do
      nil -> []
      path -> [cookies: path]
    end
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
      [percent, downloaded_bytes, total_bytes, estimated_total_bytes, eta, speed] ->
        downloaded_bytes = parse_integer(downloaded_bytes)
        total_bytes = parse_integer(total_bytes) || parse_integer(estimated_total_bytes)

        %{
          progress_percent: parse_percent(percent),
          progress_status: progress_status_for(downloaded_bytes, total_bytes),
          progress_downloaded_bytes: downloaded_bytes,
          progress_total_bytes: total_bytes,
          progress_eta_seconds: parse_integer(eta),
          progress_speed_bytes_per_second: parse_integer(speed)
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

  defp progress_status_for(nil, nil), do: "Waiting for transfer to start"
  defp progress_status_for(_downloaded_bytes, nil), do: "Downloading without known total"
  defp progress_status_for(_downloaded_bytes, _total_bytes), do: "Downloading"

  defp parse_integer(""), do: nil
  defp parse_integer("NA"), do: nil
  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp log_cmd_result(command, logging_arg_override, status, output) do
    summarized_output = summarize_log_output(output)

    log_message =
      if summarized_output == "" do
        "[command_wrapper]: #{command} called with: #{logging_arg_override} exited: #{status}"
      else
        "[command_wrapper]: #{command} called with: #{logging_arg_override} exited: #{status} with: #{summarized_output}"
      end

    log_level = if status == 0, do: :debug, else: :error

    Logger.log(log_level, log_message)
  end

  defp summarize_log_output(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&String.contains?(&1, "pinchflat-progress:"))
    |> Enum.join("\n")
    |> String.trim()
    |> truncate_output()
  end

  defp truncate_output(""), do: ""

  defp truncate_output(output) do
    max_length = 4000

    if String.length(output) <= max_length do
      output
    else
      head_length = 2000
      tail_length = 1500
      omitted_count = String.length(output) - head_length - tail_length

      String.slice(output, 0, head_length) <>
        "\n...[#{omitted_count} chars omitted]...\n" <>
        String.slice(output, -tail_length, tail_length)
    end
  end

  defp backend_executable do
    Application.get_env(:pinchflat, :yt_dlp_executable)
  end

  defp retry_self_update(command, target) do
    1..3
    |> Enum.reduce_while({:error, ""}, fn attempt, _acc ->
      case run_self_update(command, target) do
        {:ok, output} ->
          {:halt, {:ok, output}}

        {:error, output} = error ->
          if transient_update_error?(output) and attempt < 3 do
            Process.sleep(attempt * 1_000)
            {:cont, error}
          else
            {:halt, error}
          end
      end
    end)
  end

  defp run_self_update(command, target) do
    case CliUtils.wrap_cmd(command, build_update_args(target)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp maybe_fallback_to_direct_download(command, output, target) do
    if transient_update_error?(output) and target == "nightly" do
      Logger.warning("yt-dlp self-update failed with a transient network error, attempting direct nightly download")

      case direct_download_latest_nightly(command) do
        :ok ->
          {:ok, "Downloaded latest yt-dlp nightly directly after self-update failure"}

        {:error, reason} ->
          {:error, "#{output}\nFallback download failed: #{reason}"}
      end
    else
      {:error, output}
    end
  end

  defp direct_download_latest_nightly(command) do
    candidate = "#{command}.download-#{Ecto.UUID.generate()}"
    download_url = "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp"

    try do
      with {curl_output, 0} <- CliUtils.wrap_cmd(curl_executable(), ["-fL", download_url, "-o", candidate]),
           :ok <- File.chmod(candidate, 0o755),
           :ok <- validate_update_candidate(candidate),
           :ok <- File.rename(candidate, command) do
        _ = curl_output
        :ok
      else
        {curl_output, status} when is_integer(status) -> {:error, String.trim(curl_output)}
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, inspect(reason)}
      end
    after
      File.rm(candidate)
    end
  end

  defp curl_executable do
    Application.get_env(:pinchflat, :curl_executable, "curl")
  end

  defp validate_update_candidate(candidate) do
    qjs = qjs_executable()

    with :ok <- validate_qjs(qjs),
         :ok <- validate_candidate_version(candidate),
         :ok <- validate_candidate_runtime(candidate, qjs) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "Refusing to replace yt-dlp: #{reason}. The existing executable was left unchanged. " <>
           "Install QuickJS-NG at #{qjs} or pin a yt-dlp version that supports --js-runtimes."}
    end
  end

  defp validate_qjs(qjs) do
    if File.exists?(qjs) do
      case run_quietly(qjs, ["--version"]) do
        {:ok, _output} ->
          :ok

        {:error, {127, output}} ->
          {:error, "the JavaScript runtime #{qjs} could not run (exit 127: #{short_output(output)})"}

        {:error, {status, output}} ->
          {:error, "the JavaScript runtime #{qjs} exited #{status} (#{short_output(output)})"}

        {:error, description} ->
          {:error, "the JavaScript runtime #{qjs} could not run (#{description})"}
      end
    else
      {:error, "the JavaScript runtime #{qjs} could not run (not found)"}
    end
  end

  defp validate_candidate_version(candidate) do
    if File.exists?(candidate) do
      case run_quietly(candidate, ["--version"]) do
        {:ok, output} ->
          if String.trim(output) == "" do
            {:error, "the downloaded candidate returned an empty version"}
          else
            :ok
          end

        {:error, {127, output}} ->
          {:error, "the downloaded candidate could not run (exit 127: #{short_output(output)})"}

        {:error, {status, output}} ->
          {:error, "the downloaded candidate exited #{status} (#{short_output(output)})"}

        {:error, description} ->
          {:error, "the downloaded candidate could not run (#{description})"}
      end
    else
      {:error, "the downloaded candidate could not run (not found)"}
    end
  end

  defp validate_candidate_runtime(candidate, qjs) do
    args = ["--ignore-config", "--no-js-runtimes", "--js-runtimes", "quickjs:#{qjs}"]

    case run_quietly(candidate, args) do
      {:ok, _output} ->
        :ok

      {:error, {2, output}} ->
        validate_runtime_error_output(output)

      {:error, {status, output}} ->
        {:error, "the downloaded candidate exited #{status} while checking runtime options (#{short_output(output)})"}

      {:error, description} ->
        {:error, "the downloaded candidate could not run (#{description})"}
    end
  end

  defp validate_runtime_error_output(output) do
    normalized = String.downcase(output)

    cond do
      String.contains?(normalized, "no such option") ->
        {:error, "the downloaded candidate does not support the packaged runtime options (#{short_output(output)})"}

      String.contains?(normalized, "unsupported javascript runtime") ->
        {:error, "the downloaded candidate rejected the QuickJS runtime (#{short_output(output)})"}

      String.contains?(normalized, "you must provide at least one url") ->
        :ok

      true ->
        {:error, "the downloaded candidate rejected the runtime selection (#{short_output(output)})"}
    end
  end

  defp run_quietly(command, args) do
    case CliUtils.wrap_cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp short_output(output) do
    output
    |> String.trim()
    |> String.slice(0, 300)
  end

  defp transient_update_error?(output) do
    normalized_output = String.downcase(to_string(output))

    Enum.any?(
      [
        "tls/ssl connection has been closed",
        "unable to obtain version info",
        "temporary failure",
        "timed out",
        "connection reset",
        "eof"
      ],
      &String.contains?(normalized_output, &1)
    )
  end
end
