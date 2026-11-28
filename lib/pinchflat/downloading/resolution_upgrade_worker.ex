defmodule Pinchflat.Downloading.ResolutionUpgradeWorker do
  @moduledoc """
  Re-downloads a source's videos whose downloaded resolution is below what its
  media profile prefers, but only when YouTube now offers a resolution closer
  to the preference. Each candidate's formats are checked again with yt-dlp, so
  videos that finished processing higher resolutions after download are found.

  Videos downloaded before format details were recorded use the info JSON
  stored with them. Videos with neither are skipped.
  """

  use Pinchflat.Media.MediaQuery

  use Oban.Worker,
    queue: :media_fetching,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["sources", "media_fetching", "show_in_dashboard"]

  require Logger

  alias __MODULE__
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Downloading.FormatDetails
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Tasks

  @doc """
  Queues a resolution upgrade check for a source.

  Returns {:ok, %Task{}} | {:error, :duplicate_job} | {:error, %Ecto.Changeset{}}
  """
  def kickoff_with_task(source, opts \\ []) do
    %{id: source.id}
    |> ResolutionUpgradeWorker.new(opts)
    |> Tasks.create_job_with_task(source)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => source_id}}) do
    source = source_id |> Sources.get_source!() |> Repo.preload(:media_profile)

    case target_height(source.media_profile) do
      nil ->
        Logger.info("Source ##{source.id} downloads audio only; no resolution upgrade to check")

      target ->
        queued =
          MediaQuery.new()
          |> where(^MediaQuery.for_source(source))
          |> where(^MediaQuery.downloaded())
          |> Repo.all()
          |> Enum.count(&maybe_upgrade(&1, source, target))

        Logger.info("Queued #{queued} resolution upgrades for source ##{source.id} (target #{target}p)")
    end

    :ok
  rescue
    Ecto.NoResultsError -> :ok
  end

  defp maybe_upgrade(media_item, source, target) do
    media_item = Repo.preload(media_item, [:metadata, source: :media_profile])
    downloaded_height = media_item.video_height || stored_height(media_item)

    with true <- is_integer(downloaded_height) and downloaded_height < target,
         {:ok, formats} <- fetch_formats(media_item, source),
         best when is_integer(best) and best > downloaded_height <- FormatDetails.best_height_within(formats, target) do
      Media.update_media_item(media_item, %{
        video_height: downloaded_height,
        max_available_height: FormatDetails.from_info(%{"formats" => formats}).max_available_height
      })

      Logger.info("Re-downloading ##{media_item.id}: #{downloaded_height}p downloaded, #{best}p now offered")
      match?({:ok, _}, MediaDownloadWorker.kickoff_with_task(media_item, %{quality_upgrade?: true}))
    else
      _ -> false
    end
  end

  defp stored_height(%{metadata: %{metadata_filepath: path}}) when is_binary(path) do
    case File.exists?(path) && MetadataFileHelpers.read_compressed_metadata(path) do
      {:ok, info} -> FormatDetails.from_info(info).video_height
      _ -> nil
    end
  end

  defp stored_height(_media_item), do: nil

  defp fetch_formats(media_item, source) do
    command_opts =
      [:skip_download, :no_warnings, :ignore_no_formats_error] ++
        DownloadOptionBuilder.build_youtube_options_for(media_item) ++
        DownloadOptionBuilder.build_config_file_options_for(media_item)

    addl_opts = [use_cookies: Sources.use_cookies?(source, :downloading)]

    with {:ok, output} <-
           runner().run(media_item.original_url, :check_formats, command_opts, "%(.{formats})j", addl_opts),
         {:ok, %{"formats" => formats}} when is_list(formats) <- Phoenix.json_library().decode(output) do
      {:ok, formats}
    else
      error ->
        Logger.warning("Could not check formats for media item ##{media_item.id}: #{inspect(error)}")
        :error
    end
  end

  defp target_height(%{preferred_resolution: :audio}), do: nil

  defp target_height(%{preferred_resolution: resolution}) do
    {height, _} = resolution |> Atom.to_string() |> Integer.parse()
    height
  end

  defp runner, do: Application.get_env(:pinchflat, :yt_dlp_runner)
end
