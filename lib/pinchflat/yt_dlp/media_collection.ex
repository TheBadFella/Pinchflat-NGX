defmodule Pinchflat.YtDlp.MediaCollection do
  @moduledoc """
  Contains utilities for working with collections of
  media (aka: a source [ie: channels, playlists]).
  """

  require Logger

  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.YtDlp.ResponseDecoder
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @doc """
  Returns a list of maps representing the media in the collection.
  Optionally takes a list of additional command options to pass to yt-dlp
  or configuration-related options to pass to the runner.

  Runner Options:
    - :file_listener_handler - a function that will be called with the path to the
      file that will be written to when yt-dlp is done. This is useful for
      setting up a file watcher to know when the file is ready to be read.
    - :raw_metadata - return full metadata maps for single-video title/path resolution
    - :use_cookies - whether or not to use user-provided cookies when fetching the media details
    - :expected_exit_codes - passed through to the runner; non-zero exit codes the
      caller treats as a normal outcome (logged at debug instead of error)

  Returns {:ok, [map()]} | {:error, any, ...}.
  """
  def get_media_attributes_for_collection(url, command_opts \\ [], addl_opts \\ []) do
    # `ignore_no_formats_error` is necessary because yt-dlp will error out if
    # the first video has not released yet (ie: is a premier). We don't care about
    # available formats since we're just getting the media details
    all_command_opts = [:simulate, :skip_download, :ignore_no_formats_error, :no_warnings] ++ command_opts
    use_cookies = Keyword.get(addl_opts, :use_cookies, false)
    raw_metadata? = Keyword.get(addl_opts, :raw_metadata, false)
    source = Keyword.get(addl_opts, :source)
    content_type = Keyword.get(addl_opts, :content_type, :all)

    output_template =
      if raw_metadata?, do: "%()j", else: YtDlpMedia.indexing_output_template(source, content_type: content_type)

    output_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
    file_listener_handler = Keyword.get(addl_opts, :file_listener_handler, false)

    runner_opts =
      [output_filepath: output_filepath, use_cookies: use_cookies] ++
        Keyword.take(addl_opts, [:expected_exit_codes])

    action = :get_media_attributes_for_collection

    if file_listener_handler do
      file_listener_handler.(output_filepath)
    end

    case backend_runner().run(url, action, all_command_opts, output_template, runner_opts) do
      {:ok, output} ->
        parsed_lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case Phoenix.json_library().decode(line) do
              {:ok, parsed_json} ->
                if raw_metadata?,
                  do: parsed_json,
                  else: YtDlpMedia.response_to_struct(parsed_json, source, content_type: content_type)

              _ ->
                nil
            end
          end)

        {:ok, Enum.filter(parsed_lines, &(&1 != nil))}

      err ->
        err
    end
  end

  @doc """
  Gets a source's ID and name from its URL.

  yt-dlp does not _really_ have source-specific functions that return what
  we need, so instead we're fetching just the first video (using playlist_end: 1)
  and parsing the source ID and name from _its_ metadata

  The optional source_type runner option accepts automatic, channel, playlist,
  or video. Automatic preserves URL-based detection. Explicit video inspection
  uses --no-playlist; explicit channel and playlist inspection use the
  collection inspection path so the caller can validate the returned metadata.

  Returns {:ok, map()} | {:error, any, ...}.
  """
  def get_source_details(source_url, command_opts \\ [], addl_opts \\ []) do
    {source_type, addl_opts} = Keyword.pop(addl_opts, :source_type, :automatic)

    case source_type do
      :automatic ->
        if Source.youtube_video_url?(source_url) do
          get_single_video_source_details(source_url, command_opts, addl_opts)
        else
          get_collection_source_details(source_url, command_opts, addl_opts)
        end

      :video ->
        if Source.supported_youtube_url?(source_url) and not Source.youtube_video_url?(source_url) do
          {:error, "URL is not a single video"}
        else
          get_single_video_source_details(source_url, command_opts, addl_opts)
        end

      type when type in [:channel, :playlist] ->
        get_collection_source_details(source_url, command_opts, addl_opts)

      source_type ->
        {:error, "unsupported source type: #{inspect(source_type)}"}
    end
  end

  defp get_collection_source_details(source_url, command_opts, addl_opts) do
    # `ignore_no_formats_error` is necessary because yt-dlp will error out if
    # the first video has not released yet (ie: is a premier). We don't care about
    # available formats since we're just getting the source details
    default_opts = [
      :simulate,
      :skip_download,
      :ignore_no_formats_error,
      playlist_end: 1
    ]

    all_command_opts = default_opts ++ command_opts

    output_template =
      "%(.{channel,channel_id,playlist_id,playlist_title,playlist_channel,playlist_channel_id,filename})j"

    action = :get_source_details

    with {:ok, output} <- backend_runner().run(source_url, action, all_command_opts, output_template, addl_opts) do
      if String.trim(output) == "" do
        get_collection_details_without_video(source_url, command_opts, addl_opts)
      else
        with {:ok, parsed_json} <- ResponseDecoder.decode(output, action) do
          {:ok, format_source_details(parsed_json)}
        end
      end
    end
  end

  defp get_collection_details_without_video(source_url, command_opts, addl_opts) do
    # No video means no filename to predict. Read the collection itself without fetching entries.
    command_opts =
      Enum.reject(command_opts, fn
        {key, _} when key in [:playlist_items, :playlist_end] -> true
        _ -> false
      end)

    opts = [:simulate, :ignore_no_formats_error, {:playlist_items, 0}] ++ command_opts

    with {:ok, %{"_type" => "playlist", "id" => id, "title" => title} = metadata} <-
           get_source_metadata(source_url, opts, addl_opts),
         true <- collection_metadata_matches?(source_url, metadata) and is_binary(title) and String.trim(title) != "" do
      {:ok,
       format_source_details(%{
         "playlist_id" => id,
         "playlist_title" => title,
         "channel_id" => metadata["channel_id"],
         "channel" => metadata["channel"],
         "filename" => nil
       })}
    else
      {:error, _} = error -> error
      {:error, _, _} = error -> error
      _ -> {:error, :invalid_collection_metadata}
    end
  end

  defp collection_metadata_matches?(source_url, %{"id" => id} = metadata) when is_binary(id) and id != "" do
    case URI.decode_query(URI.parse(source_url).query || "")["list"] do
      playlist_id when is_binary(playlist_id) and playlist_id != "" -> id == playlist_id
      _ -> id == metadata["channel_id"]
    end
  end

  defp collection_metadata_matches?(_source_url, _metadata), do: false

  defp get_single_video_source_details(source_url, command_opts, addl_opts) do
    default_opts = [
      :simulate,
      :skip_download,
      :ignore_no_formats_error,
      :no_playlist
    ]

    all_command_opts = default_opts ++ command_opts
    output_template = "%(.{id,title,channel,channel_id,playlist_id,playlist_title,filename})j"
    action = :get_source_details

    with {:ok, output} <- backend_runner().run(source_url, action, all_command_opts, output_template, addl_opts),
         {:ok, parsed_json} <- Phoenix.json_library().decode(output),
         {:ok, source_details} <- format_single_video_source_details(parsed_json) do
      {:ok, source_details}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "Error decoding JSON response"}
      {:error, :not_a_video} -> {:error, "URL did not resolve to a single video"}
      err -> err
    end
  end

  @doc """
  Gets a source's metadata from its URL.

  This is mostly for things like getting the source's avatar and banner image
  (if applicable). However, this yt-dlp call doesn't have enough overlap with
  `get_source_details/1` to allow combining them - this one has _almost_ everything
  we need, but it doesn't contain enough information to tell 100% if the url is a channel
  or a playlist.

  The main purpose of this (past using as a fetcher for _other_ metadata) is to live
  as a compressed blob for possible future use. That's why it's not getting formatted like
  `get_source_details/1`

  ! IMPORTANT ! - you'll always want to set `playlist_items: int` in `addl_opts.
  This is great if you want to also return details about the videos in the playlists,
  but it should be set in all cases to not over-fetch data.
  For channels you should usually set this to 0 since channels return all the
  metadata we need without needing to fetch the videos. On the other hand, playlists
  don't return very useful images so you can set this to 1 to get the first video's
  images, for instance.

  Pass `:no_playlist` for a standalone video so its metadata is printed at the video stage.

  Returns {:ok, map()} | {:error, any, ...}.
  """
  def get_source_metadata(source_url, command_opts, addl_opts \\ []) do
    # This only validates that the `playlist_items` key is present. It's otherwise unused
    _playlist_items = Keyword.fetch!(command_opts, :playlist_items)

    all_command_opts = [:skip_download] ++ command_opts
    output_template = if :no_playlist in command_opts, do: "%()j", else: "playlist:%()j"
    action = :get_source_metadata

    with {:ok, output} <- backend_runner().run(source_url, action, all_command_opts, output_template, addl_opts) do
      ResponseDecoder.decode(output, action)
    end
  end

  @doc """
  Fetches the translated titles for a collection listing.

  Runs one flat-playlist request against the given listing URL with
  `youtube:lang=<language>` so the listing returns titles in that language.
  Only media IDs and titles are requested.

  Any `extractor_args` in `command_opts` or `addl_opts` are preserved and merged
  with the requested language. Additional command options (such as
  `playlist_end: N`) are appended so callers can bound the listing.

  The returned map contains what the listing reported. Deciding whether a title
  is an actual translation is left to the caller.

  Returns `{:ok, %{media_id => title}}` | `{:error, reason}`.
  """
  def get_translated_titles(url, language, command_opts \\ [], addl_opts \\ []) do
    output_template = "%(.{id,title})j"
    action = :get_translated_titles

    {command_extractor_args, command_opts} = Keyword.pop_values(command_opts, :extractor_args)
    {addl_extractor_args, addl_opts} = Keyword.pop_values(addl_opts, :extractor_args)

    extractor_args =
      (command_extractor_args ++ addl_extractor_args)
      |> merge_youtube_language(language)
      |> Enum.map(&{:extractor_args, &1})

    all_command_opts = [:flat_playlist, :skip_download] ++ extractor_args ++ command_opts

    case backend_runner().run(url, action, all_command_opts, output_template, addl_opts) do
      {:ok, output} -> {:ok, parse_translated_titles(output)}
      {:error, reason} -> {:error, reason}
      {:error, reason, status} -> {:error, {reason, status}}
      other -> {:error, other}
    end
  end

  @doc """
  Fetches translated titles for a source's listing URLs in the source's `title_language`.

  Returns an empty map when the source has no title language or isn't a YouTube channel or
  playlist. A failed or empty listing is logged and contributes no titles, so indexing continues
  with original titles only. Translated titles must be fetched before media items are created,
  because downloads can be enqueued immediately and the output path is built at download time.

  Returns %{media_id => title}
  """
  def get_source_translated_titles(source, urls, command_opts \\ [])

  def get_source_translated_titles(%Source{title_language: nil}, _urls, _command_opts), do: %{}

  def get_source_translated_titles(%Source{collection_type: type} = source, urls, command_opts)
      when type in [:channel, :playlist] do
    if Source.supported_youtube_url?(source.original_url) do
      Enum.reduce(urls, %{}, fn url, titles ->
        case get_translated_titles(url, source.title_language, command_opts) do
          {:ok, listing_titles} ->
            if map_size(listing_titles) == 0 do
              Logger.info("translated_titles_listing_empty source_id=#{source.id} url=#{url}")
            end

            Map.merge(titles, listing_titles)

          {:error, reason} ->
            Logger.info("translated_titles_listing_failed source_id=#{source.id} url=#{url} reason=#{inspect(reason)}")
            titles
        end
      end)
    else
      %{}
    end
  end

  def get_source_translated_titles(_source, _urls, _command_opts), do: %{}

  @doc """
  Picks the translated title for indexed media from a `get_source_translated_titles/3` result.
  Blank titles and titles identical to the original aren't translations.

  Returns binary() | nil
  """
  def translated_title_for(%{media_id: media_id, title: title}, translated_titles) when is_binary(media_id) do
    case Map.get(translated_titles, media_id) do
      translated when is_binary(translated) ->
        if String.trim(translated) != "" and translated != title, do: translated

      _ ->
        nil
    end
  end

  def translated_title_for(_media_attrs, _translated_titles), do: nil

  defp merge_youtube_language([], language), do: ["youtube:lang=#{language}"]

  defp merge_youtube_language(extractor_args, language) do
    case Enum.find_index(extractor_args, &youtube_extractor_args?/1) do
      nil -> extractor_args ++ ["youtube:lang=#{language}"]
      index -> List.update_at(extractor_args, index, &put_youtube_language(&1, language))
    end
  end

  defp youtube_extractor_args?("youtube:" <> _rest), do: true
  defp youtube_extractor_args?(_extractor_args), do: false

  defp put_youtube_language("youtube:" <> rest, language) do
    keys =
      rest
      |> String.split(";", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "lang="))

    "youtube:" <> Enum.join(keys ++ ["lang=#{language}"], ";")
  end

  defp parse_translated_titles(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, titles ->
      case decode_translated_title(line) do
        {media_id, title} -> Map.put(titles, media_id, title)
        nil -> titles
      end
    end)
  end

  defp decode_translated_title(line) do
    with true <- String.trim(line) != "",
         {:ok, %{"id" => media_id, "title" => title}} <- Phoenix.json_library().decode(line),
         true <- is_binary(media_id) and is_binary(title) do
      {media_id, title}
    else
      _ -> nil
    end
  end

  defp format_source_details(response) do
    # Collection ownership is available even when the first video's channel metadata is missing.
    response =
      response
      |> Map.put("channel_id", response["playlist_channel_id"] || response["channel_id"])
      |> Map.put("channel", response["playlist_channel"] || response["channel"])

    # NOTE: I should probably make this a struct some day
    %{
      source_type: :collection,
      detected_type: detected_collection_type(response),
      channel_id: response["channel_id"],
      channel_name: response["channel"],
      playlist_id: response["playlist_id"],
      playlist_name: response["playlist_title"],
      # It's not a name, it's a path dammit!
      # This actually isn't used for the inital response - it's
      # used later to update a source's metadata
      filepath: response["filename"]
    }
  end

  defp format_single_video_source_details(response) do
    if is_binary(response["id"]) and is_binary(response["title"]) do
      {:ok,
       %{
         source_type: :video,
         detected_type: :video,
         video_id: response["id"],
         video_title: response["title"],
         channel_id: response["channel_id"],
         channel_name: response["channel"],
         playlist_id: response["playlist_id"],
         playlist_name: response["playlist_title"],
         filepath: response["filename"]
       }}
    else
      {:error, :not_a_video}
    end
  end

  defp detected_collection_type(%{"channel_id" => channel_id, "playlist_id" => playlist_id})
       when is_binary(channel_id) and channel_id == playlist_id,
       do: :channel

  defp detected_collection_type(%{"playlist_id" => playlist_id}) when is_binary(playlist_id), do: :playlist
  defp detected_collection_type(_response), do: :unknown

  defp backend_runner do
    # This approach lets us mock the command for testing
    Application.get_env(:pinchflat, :yt_dlp_runner)
  end
end
