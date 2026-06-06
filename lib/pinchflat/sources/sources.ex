defmodule Pinchflat.Sources do
  @moduledoc """
  The Sources context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery
  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.FastIndexing.FastIndexingHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  @doc """
  Returns the configured path to the shared cookie file.

  Returns binary()
  """
  def cookie_file_path do
    Path.join(Application.get_env(:pinchflat, :extras_directory), "cookies.txt")
  end

  @doc """
  Returns whether the shared cookie file exists on disk.

  Returns boolean()
  """
  def cookie_file_exists? do
    File.exists?(cookie_file_path())
  end

  @doc """
  Returns whether the shared cookie file exists and has non-whitespace contents.

  Returns boolean()
  """
  def cookie_file_configured? do
    FilesystemUtils.exists_and_nonempty?(cookie_file_path())
  end

  @doc """
  Reads the shared cookie file.

  Returns {:ok, binary()} | {:error, any()}
  """
  def read_cookie_file do
    File.read(cookie_file_path())
  end

  @doc """
  Writes contents to the shared cookie file, creating parent directories as needed.

  Returns :ok | {:error, any()}
  """
  def write_cookie_file(contents) when is_binary(contents) do
    FilesystemUtils.write_p(cookie_file_path(), contents)
  end

  @doc """
  Copies an uploaded file into the shared cookie file path, creating parent directories as needed.

  Returns :ok | {:error, any()}
  """
  def save_uploaded_cookie_file(%Plug.Upload{path: source_path}) do
    case File.read(source_path) do
      {:ok, contents} -> write_cookie_file(contents)
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Returns the relevant output path template for a source.
  Pulls from the source's override if present, otherwise uses the media profile's.

  Returns binary()
  """
  def output_path_template(source) do
    source = Repo.preload(source, :media_profile)
    media_profile = source.media_profile

    source.output_path_template_override || media_profile.output_path_template
  end

  @doc """
  Returns a boolean indicating whether or not cookies should be used for a given operation.

  Returns boolean()
  """
  def use_cookies?(source, operation) when operation in [:indexing, :downloading, :metadata, :error_recovery] do
    case source.cookie_behaviour do
      :disabled -> false
      :all_operations -> true
      :when_needed -> operation in [:indexing, :error_recovery]
    end
  end

  @doc """
  Returns the list of sources. Returns [%Source{}, ...]
  """
  def list_sources do
    Repo.all(Source)
  end

  @doc """
  Preloads associations used by API serialization.

  Returns [%Source{}, ...] | %Source{}.
  """
  def preload_api_assocs(sources) do
    Repo.preload(sources, :media_profile)
  end

  @doc """
  Returns the list of sources for a media_profile.

  Returns [%Source{}, ...]
  """
  def list_sources_for(%MediaProfile{} = media_profile) do
    Repo.all(from s in Source, where: s.media_profile_id == ^media_profile.id)
  end

  @doc """
  Gets a single source.

  Returns %Source{}. Raises `Ecto.NoResultsError` if the Source does not exist.
  """
  def get_source!(id), do: Repo.get!(Source, id)

  @doc """
  Creates a source. May attempt to pull additional source details from the
  original_url (if provided). Will attempt to start indexing the source's
  media if successfully inserted.

  Runs an initial `change_source` check to ensure most of the source is valid
  before making an expensive API call. Runs it through `Repo.insert` even
  though we know it's going to fail so it picks up any addl. database errors
  and fulfills our return contract.

  You can pass options to control the behavior of the function:
    - `run_post_commit_tasks` (default: true) - If false, the function will not
      enqueue any tasks in `commit_and_handle_tasks`.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def create_source(attrs, opts \\ []) do
    case change_source(%Source{}, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        %Source{}
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> maybe_enable_manual_selection(opts)
        |> commit_and_handle_tasks(opts)

      changeset ->
        Repo.insert(changeset)
    end
  end

  @doc """
  Updates a source. May attempt to pull additional source details from the
  original_url (if changed). May attempt to start indexing the source's
  media if the indexing frequency has been changed.

  Existing indexing tasks will be cancelled if the indexing frequency has been
  changed (logic in `SlowIndexingHelpers.kickoff_indexing_task`)

  Runs an initial `change_source` check to ensure most of the source is valid
  before making an expensive API call. Runs it through `Repo.update` even
  though we know it's going to fail so it picks up any addl. database errors
  and fulfills our return contract.

  You can pass options to control the behavior of the function:
    - `run_post_commit_tasks` (default: true) - If false, the function will not
      enqueue any tasks in `commit_and_handle_tasks`.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def update_source(%Source{} = source, attrs, opts \\ []) do
    case change_source(source, attrs, :initial) do
      %Ecto.Changeset{valid?: true} ->
        source
        |> maybe_change_source_from_url(attrs)
        |> maybe_change_indexing_frequency()
        |> maybe_change_source_directory_paths()
        |> maybe_prevent_conflicting_source_directory_move()
        |> commit_and_handle_tasks(opts)

      changeset ->
        Repo.update(changeset)
    end
  end

  @doc """
  Builds a preview for the filesystem move caused by changing a source's download subdirectory.

  Returns {:ok, map() | nil} | {:error, %Ecto.Changeset{}}
  """
  def preview_source_directory_move(%Source{} = source, attrs) do
    case change_source(source, attrs, :initial) do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, source_directory_move_plan(changeset)}

      changeset ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a source, its media items, and its associated tasks (of any state).
  Can optionally delete the source's media files.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_source(%Source{} = source, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)
    Tasks.delete_tasks_for(source)

    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> Repo.all()
    |> Enum.each(fn media_item ->
      Media.delete_media_item(media_item, delete_files: delete_files)
    end)

    if delete_files do
      delete_source_files(source)
    end

    delete_internal_metadata_files(source)
    Repo.delete(source)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source changes.
  """
  def change_source(%Source{} = source, attrs \\ %{}, validation_stage \\ :pre_insert) do
    Source.changeset(source, attrs, validation_stage)
  end

  @doc """
  Applies manual playlist selection to a source.

  Selected media items will have `prevent_download: false`. All others will be
  marked `prevent_download: true`. If `enable_downloads` is true, the source is
  switched to downloading mode and only the selected pending items are enqueued.
  """
  def apply_media_selection(%Source{} = source, selected_media_item_ids, opts \\ []) do
    enable_downloads = Keyword.get(opts, :enable_downloads, false)
    selected_ids = normalize_media_item_ids(selected_media_item_ids)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(:exclude_unselected, media_items_for_source_query(source), set: [prevent_download: true])
      |> maybe_include_selected_items(source, selected_ids)
      |> maybe_enable_source_downloads(source, enable_downloads)

    case Repo.transaction(multi) do
      {:ok, _changes} ->
        source = Repo.reload!(source)

        if enable_downloads do
          source
          |> Media.list_pending_media_items_for_ids(selected_ids)
          |> Enum.each(&MediaDownloadWorker.kickoff_with_task/1)
        end

        {:ok, source}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Restores a manually-selected playlist source to normal automatic downloads.

  This switches the source back to `selection_mode: :all`, enables downloads,
  and clears any existing `prevent_download` flags for the source's media items.

  Returns {:ok, %Source{}} | {:error, %Ecto.Changeset{}}
  """
  def restore_automatic_downloads(%Source{} = source) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:source, change_source(source, %{selection_mode: :all, download_media: true}, :initial))
      |> Ecto.Multi.update_all(:restore_media_items, media_items_for_source_query(source),
        set: [prevent_download: false]
      )

    case Repo.transaction(multi) do
      {:ok, _changes} ->
        source = Repo.reload!(source)

        if source.enabled do
          DownloadingHelpers.enqueue_pending_download_tasks(source)
        end

        {:ok, source}

      {:error, :source, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # NOTE: When operating in the ideal path, this effectively adds an API call
  # to the source creation/update process. Should be used only when needed.
  defp maybe_change_source_from_url(%Source{} = source, attrs) do
    case change_source(source, attrs) do
      %Ecto.Changeset{changes: %{original_url: _}} = changeset ->
        add_source_details_to_changeset(source, changeset)

      changeset ->
        changeset
    end
  end

  defp delete_source_files(source) do
    mapped_struct = Map.from_struct(source)

    Source.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp delete_internal_metadata_files(source) do
    metadata = Repo.preload(source, :metadata).metadata || %SourceMetadata{}
    mapped_struct = Map.from_struct(metadata)

    SourceMetadata.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp add_source_details_to_changeset(source, changeset) do
    original_url = changeset.changes.original_url
    should_use_cookies = Ecto.Changeset.get_field(changeset, :cookie_behaviour) == :all_operations
    # Skipping sleep interval since this is UI blocking and we want to keep this as fast as possible
    addl_opts = [use_cookies: should_use_cookies, skip_sleep_interval: true]

    case MediaCollection.get_source_details(original_url, [], addl_opts) do
      {:ok, source_details} ->
        add_source_details_by_collection_type(source, changeset, source_details)

      err ->
        runner_error =
          case err do
            {:error, error_msg, _status_code} -> error_msg
            {:error, error_msg} -> error_msg
          end

        Ecto.Changeset.add_error(
          changeset,
          :original_url,
          "could not fetch source details from URL",
          error: runner_error
        )
    end
  end

  defp add_source_details_by_collection_type(source, changeset, source_details) do
    %Ecto.Changeset{changes: changes} = changeset

    collection_changes =
      if source_details.source_type == :video do
        %{
          collection_type: :video,
          collection_id: source_details.video_id,
          collection_name: source_details.video_title
        }
      else
        if source_details.playlist_id == source_details.channel_id do
          %{
            collection_type: :channel,
            collection_id: source_details.channel_id,
            collection_name: source_details.channel_name
          }
        else
          %{
            collection_type: :playlist,
            collection_id: source_details.playlist_id,
            collection_name: source_details.playlist_name
          }
        end
      end

    change_source(source, Map.merge(changes, collection_changes))
  end

  defp maybe_change_indexing_frequency(changeset) do
    changeset
    |> maybe_disable_recurring_indexing_for_single_video()
    |> maybe_change_fast_index_frequency()
  end

  defp maybe_change_source_directory_paths(
         %{
           data: %{__meta__: %{state: :loaded}, series_directory: old_series_directory},
           changes: changes
         } = changeset
       )
       when is_binary(old_series_directory) and is_map_key(changes, :download_subdirectory) do
    new_series_directory = source_directory_for(changes.download_subdirectory)

    if same_path?(old_series_directory, new_series_directory) do
      changeset
    else
      changeset
      |> Ecto.Changeset.put_change(:series_directory, new_series_directory)
      |> maybe_relocate_source_filepath_attrs(old_series_directory, new_series_directory)
    end
  end

  defp maybe_change_source_directory_paths(changeset), do: changeset

  defp maybe_prevent_conflicting_source_directory_move(changeset) do
    case source_directory_move_plan(changeset) do
      %{conflicts: [_ | _]} ->
        Ecto.Changeset.add_error(
          changeset,
          :download_subdirectory,
          "cannot move files because the destination already contains files with the same names"
        )

      _ ->
        changeset
    end
  end

  defp source_directory_move_plan(%{
         data: %{__meta__: %{state: :loaded}, series_directory: old_series_directory},
         changes: changes
       })
       when is_binary(old_series_directory) and is_map_key(changes, :download_subdirectory) do
    new_series_directory = source_directory_for(changes.download_subdirectory)

    if same_path?(old_series_directory, new_series_directory) do
      nil
    else
      %{
        old_directory: old_series_directory,
        new_directory: new_series_directory,
        old_directory_exists: File.dir?(old_series_directory),
        new_directory_exists: File.exists?(new_series_directory),
        file_count: count_files(old_series_directory),
        conflicts: move_conflicts(old_series_directory, new_series_directory)
      }
    end
  end

  defp source_directory_move_plan(_changeset), do: nil

  defp source_directory_for(nil), do: Application.get_env(:pinchflat, :media_directory)

  defp source_directory_for(subdirectory),
    do: Path.join(Application.get_env(:pinchflat, :media_directory), subdirectory)

  defp maybe_relocate_source_filepath_attrs(changeset, old_directory, new_directory) do
    Source.filepath_attributes()
    |> Enum.reject(&Map.has_key?(changeset.changes, &1))
    |> Enum.reduce(changeset, fn field, acc ->
      value = Map.get(acc.data, field)

      case relocate_filepath(value, old_directory, new_directory) do
        ^value -> acc
        relocated_value -> Ecto.Changeset.put_change(acc, field, relocated_value)
      end
    end)
  end

  defp maybe_enable_manual_selection(changeset, opts) do
    if Keyword.get(opts, :delay_automatic_download, false) &&
         Ecto.Changeset.get_field(changeset, :collection_type) == :playlist do
      changeset
      |> Ecto.Changeset.put_change(:selection_mode, :manual)
      |> Ecto.Changeset.put_change(:download_media, false)
    else
      changeset
    end
  end

  defp maybe_disable_recurring_indexing_for_single_video(changeset) do
    if Ecto.Changeset.get_field(changeset, :collection_type) == :video do
      changeset
      |> Ecto.Changeset.put_change(:fast_index, false)
      |> Ecto.Changeset.put_change(:index_frequency_minutes, 0)
    else
      changeset
    end
  end

  defp maybe_change_fast_index_frequency(changeset) do
    fast_index = Ecto.Changeset.get_field(changeset, :fast_index)

    if fast_index do
      Ecto.Changeset.put_change(
        changeset,
        :index_frequency_minutes,
        Source.index_frequency_when_fast_indexing()
      )
    else
      changeset
    end
  end

  defp commit_and_handle_tasks(changeset, opts) do
    run_post_commit_tasks = Keyword.get(opts, :run_post_commit_tasks, true)

    case Repo.insert_or_update(changeset) do
      {:ok, %Source{} = source} ->
        log_source_created(changeset, source)
        source = maybe_move_existing_source_files(changeset, source)

        if run_post_commit_tasks do
          maybe_handle_media_tasks(changeset, source)
          maybe_run_indexing_task(changeset, source)
          maybe_run_metadata_storage_task(changeset, source)
        end

        {:ok, source}

      err ->
        err
    end
  end

  defp maybe_move_existing_source_files(
         %{
           data: %{__meta__: %{state: :loaded}, series_directory: old_series_directory} = old_source,
           changes: %{download_subdirectory: _}
         },
         %Source{series_directory: new_series_directory} = source
       )
       when is_binary(old_series_directory) and is_binary(new_series_directory) do
    if same_path?(old_series_directory, new_series_directory) do
      source
    else
      case move_directory_contents(old_series_directory, new_series_directory) do
        :ok ->
          update_media_filepaths_for_source(old_source, old_series_directory, new_series_directory)
          Repo.reload!(source)

        {:error, reason} ->
          Logger.warning(
            "source_directory_move_failed source_id=#{source.id} old_directory=#{old_series_directory} " <>
              "new_directory=#{new_series_directory} reason=#{inspect(reason)}"
          )

          source
      end
    end
  end

  defp maybe_move_existing_source_files(_changeset, source), do: source

  defp move_directory_contents(old_directory, new_directory) do
    if File.dir?(old_directory) do
      move_path(old_directory, new_directory)
    else
      :ok
    end
  end

  defp move_conflicts(old_directory, new_directory) do
    cond do
      !File.dir?(old_directory) ->
        []

      !File.exists?(new_directory) ->
        []

      true ->
        do_move_conflicts(old_directory, new_directory)
    end
  end

  defp do_move_conflicts(source_path, destination_path) do
    cond do
      File.dir?(source_path) && File.dir?(destination_path) ->
        source_path
        |> File.ls!()
        |> Enum.flat_map(fn entry ->
          do_move_conflicts(Path.join(source_path, entry), Path.join(destination_path, entry))
        end)

      File.exists?(destination_path) ->
        [destination_path]

      true ->
        []
    end
  end

  defp count_files(directory) do
    if File.dir?(directory) do
      directory
      |> File.ls!()
      |> Enum.map(&Path.join(directory, &1))
      |> Enum.reduce(0, fn path, acc ->
        if File.dir?(path), do: acc + count_files(path), else: acc + 1
      end)
    else
      0
    end
  end

  defp move_path(source_path, destination_path) do
    cond do
      File.dir?(source_path) && File.dir?(destination_path) ->
        source_path
        |> File.ls!()
        |> Enum.reduce_while(:ok, fn entry, _acc ->
          case move_path(Path.join(source_path, entry), Path.join(destination_path, entry)) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> tap(fn
          :ok -> remove_empty_directory(source_path)
          _ -> :ok
        end)

      File.exists?(destination_path) ->
        {:error, :eexist}

      true ->
        destination_path
        |> Path.dirname()
        |> File.mkdir_p()
        |> case do
          :ok -> File.rename(source_path, destination_path)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp remove_empty_directory(directory) do
    case File.rmdir(directory) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp update_media_filepaths_for_source(source, old_directory, new_directory) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> Repo.all()
    |> Enum.each(fn media_item ->
      attrs =
        MediaItem.filepath_attributes()
        |> Enum.map(fn
          :subtitle_filepaths = field ->
            {field, relocate_subtitle_filepaths(media_item.subtitle_filepaths, old_directory, new_directory)}

          field ->
            {field, relocate_filepath(Map.get(media_item, field), old_directory, new_directory)}
        end)
        |> Enum.reject(fn {field, value} -> value == Map.get(media_item, field) end)
        |> Enum.into(%{})

      if map_size(attrs) > 0 do
        Media.update_media_item(media_item, attrs)
      end
    end)
  end

  defp relocate_subtitle_filepaths(subtitle_filepaths, old_directory, new_directory) do
    Enum.map(subtitle_filepaths || [], fn
      [language, filepath] when is_binary(filepath) ->
        [language, relocate_filepath(filepath, old_directory, new_directory)]

      subtitle ->
        subtitle
    end)
  end

  defp relocate_filepath(filepath, old_directory, new_directory) when is_binary(filepath) do
    if path_under_directory?(filepath, old_directory) do
      Path.join(new_directory, Path.relative_to(filepath, old_directory))
    else
      filepath
    end
  end

  defp relocate_filepath(filepath, _old_directory, _new_directory), do: filepath

  defp same_path?(path_1, path_2) do
    Path.expand(path_1) == Path.expand(path_2)
  end

  defp path_under_directory?(filepath, directory) do
    expanded_filepath = Path.expand(filepath)
    expanded_directory = Path.expand(directory)

    expanded_filepath == expanded_directory ||
      String.starts_with?(expanded_filepath, expanded_directory <> directory_separator(expanded_directory))
  end

  defp directory_separator(path) do
    if String.contains?(path, "\\"), do: "\\", else: "/"
  end

  # If the source is new (ie: not persisted), do nothing
  defp maybe_handle_media_tasks(%{data: %{__meta__: %{state: state}}}, _source) when state != :loaded do
    :ok
  end

  # If the source is NOT new (ie: updated),
  # enqueue or dequeue media download tasks as necessary.
  defp maybe_handle_media_tasks(changeset, source) do
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    # We need both current_changes and applied_changes to determine
    # the course of action to take. For example, we only care if a source is supposed
    # to be `enabled` or not - we don't care if that information comes from the
    # current changes or if that's how it already was in the database.
    # Rephrased, we're essentially using it in place of `get_field/2`
    case {current_changes, applied_changes} do
      {%{download_media: true}, %{enabled: true}} ->
        DownloadingHelpers.enqueue_pending_download_tasks(source)

      {%{enabled: true}, %{download_media: true}} ->
        DownloadingHelpers.enqueue_pending_download_tasks(source)

      {%{download_media: false}, _} ->
        DownloadingHelpers.dequeue_pending_download_tasks(source)

      {%{enabled: false}, _} ->
        DownloadingHelpers.dequeue_pending_download_tasks(source)

      _ ->
        nil
    end

    :ok
  end

  defp maybe_run_indexing_task(changeset, source) do
    case changeset.data do
      # If the changeset is new (not persisted), attempt indexing no matter what
      %{__meta__: %{state: :built}} ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

        if Ecto.Changeset.get_field(changeset, :fast_index) do
          FastIndexingHelpers.kickoff_indexing_task(source)
        end

      # If the record has been persisted, only run indexing if the
      # indexing frequency has been changed and is now greater than 0
      %{__meta__: %{state: :loaded}} ->
        maybe_update_slow_indexing_task(changeset, source)
        maybe_update_fast_indexing_task(changeset, source)
    end
  end

  defp maybe_run_metadata_storage_task(changeset, source) do
    case {changeset.data, changeset.changes} do
      # If the changeset is new (not persisted), fetch metadata no matter what
      {%{__meta__: %{state: :built}}, _} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      # If the record has been persisted, only fetch metadata if the
      # original_url has changed
      {_, %{original_url: _}} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      # If the media_profile_id has changed, re-fetch metadata to potentially
      # download source images if the new profile has download_source_images enabled
      {_, %{media_profile_id: _}} ->
        SourceMetadataStorageWorker.kickoff_with_task(source)

      _ ->
        :ok
    end
  end

  defp maybe_update_slow_indexing_task(changeset, source) do
    # See comment in `maybe_handle_media_tasks` as to why we need these
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    case {current_changes, applied_changes} do
      {%{index_frequency_minutes: mins}, %{enabled: true}} when mins > 0 ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

      {%{enabled: true}, %{index_frequency_minutes: mins}} when mins > 0 ->
        SlowIndexingHelpers.kickoff_indexing_task(source)

      {%{index_frequency_minutes: _}, _} ->
        SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)

      {%{enabled: false}, _} ->
        SlowIndexingHelpers.delete_indexing_tasks(source, include_executing: true)

      _ ->
        :ok
    end
  end

  defp maybe_update_fast_indexing_task(changeset, source) do
    # See comment in `maybe_handle_media_tasks` as to why we need these
    current_changes = changeset.changes
    applied_changes = Ecto.Changeset.apply_changes(changeset)

    # This technically could be simplified since `maybe_update_slow_indexing_task`
    # has some overlap re: deleting pending tasks, but I'm keeping it separate
    # for clarity and explicitness.
    case {current_changes, applied_changes} do
      {%{fast_index: true}, %{enabled: true}} ->
        FastIndexingHelpers.kickoff_indexing_task(source)

      {%{enabled: true}, %{fast_index: true}} ->
        FastIndexingHelpers.kickoff_indexing_task(source)

      {%{fast_index: false}, _} ->
        Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)

      {%{enabled: false}, _} ->
        Tasks.delete_pending_tasks_for(source, "FastIndexingWorker", include_executing: true)

      _ ->
        :ok
    end
  end

  defp maybe_include_selected_items(multi, _source, []), do: multi

  defp maybe_include_selected_items(multi, source, selected_ids) do
    Ecto.Multi.update_all(
      multi,
      :include_selected,
      media_items_for_source_query(source, selected_ids),
      set: [prevent_download: false]
    )
  end

  defp maybe_enable_source_downloads(multi, _source, false), do: multi

  defp maybe_enable_source_downloads(multi, source, true) do
    changeset = change_source(source, %{download_media: true}, :initial)
    Ecto.Multi.update(multi, :enable_downloads, changeset)
  end

  defp media_items_for_source_query(source, selected_ids \\ nil) do
    query =
      MediaQuery.new()
      |> where(^MediaQuery.for_source(source))

    if is_list(selected_ids) do
      where(query, [m], m.id in ^selected_ids)
    else
      query
    end
  end

  defp normalize_media_item_ids(media_item_ids) do
    media_item_ids
    |> List.wrap()
    |> Enum.map(fn
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {parsed_id, ""} -> parsed_id
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp log_source_created(%{data: %{__meta__: %{state: :built}}}, %Source{} = source) do
    Logger.info(
      "source_created source_id=#{source.id} collection_type=#{source.collection_type} " <>
        "selection_mode=#{source.selection_mode} download_media=#{source.download_media} enabled=#{source.enabled}"
    )
  end

  defp log_source_created(_changeset, _source), do: :ok
end
