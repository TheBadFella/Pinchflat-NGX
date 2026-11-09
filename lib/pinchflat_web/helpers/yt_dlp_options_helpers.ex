defmodule PinchflatWeb.YtDlpOptionsHelpers do
  @moduledoc false

  alias Pinchflat.Settings.YtDlpConfigFile

  @base_assigns %{
    yt_dlp_options: "",
    yt_dlp_options_version: :missing,
    yt_dlp_options_present: false,
    yt_dlp_options_readable: true,
    yt_dlp_options_clearable: false,
    yt_dlp_options_clear?: false,
    yt_dlp_options_edited?: false,
    yt_dlp_options_inherited: %{},
    yt_dlp_options_profile_presence: %{},
    yt_dlp_error: nil
  }

  def base_assigns, do: @base_assigns

  def payload(params, default \\ :absent) do
    cond do
      truthy?(params["yt_dlp_options_clear"]) -> {:present, ""}
      Map.has_key?(params, "yt_dlp_options") -> {:present, to_string(params["yt_dlp_options"])}
      true -> default
    end
  end

  def expected_version(params, default \\ :any) do
    case params["yt_dlp_options_version"] do
      "missing" -> :missing
      "any" -> :any
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  def options_opts(params, default_version \\ :any) do
    [
      yt_dlp_options: payload(params),
      yt_dlp_options_version: expected_version(params, default_version)
    ]
  end

  def load_assigns(scope, id, inherited \\ %{}, profile_presence \\ %{}) do
    case YtDlpConfigFile.read_scope(scope, id) do
      {:ok, %{contents: contents, version: version, present?: present?}} ->
        %{
          @base_assigns
          | yt_dlp_options: contents,
            yt_dlp_options_version: version,
            yt_dlp_options_present: present?,
            yt_dlp_options_clearable: present?,
            yt_dlp_options_inherited: inherited,
            yt_dlp_options_profile_presence: profile_presence
        }

      {:error, :too_large, %{size: size}} ->
        %{
          @base_assigns
          | yt_dlp_options_version: :any,
            yt_dlp_options_present: true,
            yt_dlp_options_readable: false,
            yt_dlp_options_clearable: true,
            yt_dlp_options_inherited: inherited,
            yt_dlp_options_profile_presence: profile_presence,
            yt_dlp_error:
              "This config file is #{size} bytes, larger than the #{YtDlpConfigFile.max_bytes()}-byte editor limit. " <>
                "It is preserved and downloads still use it. Clear it explicitly to replace it."
        }

      {:error, :unreadable, _path} ->
        %{
          @base_assigns
          | yt_dlp_options_version: :any,
            yt_dlp_options_readable: false,
            yt_dlp_options_clearable: false,
            yt_dlp_options_inherited: inherited,
            yt_dlp_options_profile_presence: profile_presence,
            yt_dlp_error: "This config file could not be read. It is left untouched."
        }

      {:error, reason} ->
        %{
          @base_assigns
          | yt_dlp_options_inherited: inherited,
            yt_dlp_options_profile_presence: profile_presence,
            yt_dlp_error: message(reason)
        }
    end
  end

  def submitted_assigns(params, inherited \\ %{}, profile_presence \\ %{}, error \\ nil, default_version \\ :any) do
    contents =
      case payload(params, {:present, ""}) do
        {:present, contents} -> contents
        :absent -> ""
      end

    version = expected_version(params, default_version)
    clear? = truthy?(params["yt_dlp_options_clear"])
    present? = String.trim(contents) != ""

    %{
      @base_assigns
      | yt_dlp_options: contents,
        yt_dlp_options_version: version,
        yt_dlp_options_present: present?,
        yt_dlp_options_clearable: present? or (clear? and version not in [:missing]),
        yt_dlp_options_clear?: clear?,
        yt_dlp_options_edited?: true,
        yt_dlp_options_inherited: inherited,
        yt_dlp_options_profile_presence: profile_presence,
        yt_dlp_error: error
    }
  end

  def message(:stale_conflict) do
    "Someone else changed this config file after you opened it. Your draft is preserved. " <>
      "Reload the page to see the current file, or save again to use your draft."
  end

  def message(:stale), do: message(:stale_conflict)

  def message(:too_large) do
    "The config file is larger than the #{YtDlpConfigFile.max_bytes()}-byte limit. It was preserved."
  end

  def message(:unreadable), do: "The config file could not be read. It was left untouched."

  def message(:unsafe_path), do: "The config file path is not safe."

  def message(reason) when is_atom(reason) do
    "Could not save custom yt-dlp options: #{reason}"
  end

  def message(reason) do
    "Could not save custom yt-dlp options: #{inspect(reason)}"
  end

  def truthy?(value), do: value in [true, "true", "1", "on", 1]
end
