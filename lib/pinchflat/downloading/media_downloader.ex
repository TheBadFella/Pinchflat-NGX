defmodule Pinchflat.Downloading.MediaDownloader do
  @moduledoc """
  This is the integration layer for actually downloading media.
  It takes into account the media profile's settings in order
  to download the media with the desired options.
  """

  require Logger

  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.Downloading.FirstArtifact
  alias Pinchflat.Downloading.DownloadStaging
  alias Pinchflat.Media
  alias Pinchflat.Media.DownloadState
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.MediaWatch
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Metadata.MetadataParser
  alias Pinchflat.Metadata.NfoBuilder
  alias Pinchflat.Repo
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Utils.StringUtils

  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  @doc """
  Downloads media for a media item, updating the media item based on the metadata
  returned by yt-dlp. Encountered errors are saved to the Media Item record. Saves
  the entire metadata response to the associated media_metadata record.

  NOTE: related methods (like the download worker) won't download if Pthe media item's source
  is set to not download media. However, I'm not enforcing that here since I need this for testing.
  This may change in the future but I'm not stressed.

  Returns {:ok, %MediaItem{}} | {:error, atom(), String.t()} | {:recovered, %MediaItem{}, String.t()}
  """
  def download_for_media_item(%MediaItem{} = media_item, override_opts \\ []) do
    case attempt_download_and_update_for_media_item(media_item, override_opts) do
      {:ok, media_item} ->
        # Returns {:ok, %MediaItem{}}
        Media.update_media_item(media_item, DownloadState.transition(media_item, :success))

      {:error, guard_reason, message}
      when guard_reason in [:cancelled, :migration_hold, :insufficient_storage] ->
        {:error, guard_reason, message}

      {:error, error_atom, message} ->
        Media.update_media_item(reload_media_item_for_last_error(media_item), %{
          last_error: persisted_last_error(media_item, message)
        })

        {:error, error_atom, message}

      {:error, %Ecto.Changeset{}} ->
        {:error, :artifact_persistence_failed, "The downloaded artifact could not be recorded; retry safely"}

      {:recovered, media_item, message} ->
        {:ok, updated_media_item} =
          Media.update_media_item(reload_media_item_for_last_error(media_item), %{
            last_error: persisted_last_error(media_item, message)
          })

        {:recovered, updated_media_item, message}
    end
  end

  # Looks complicated, but here's the key points:
  # - download_with_options runs a pre-check to see if the media item is suitable for download.
  # - If the media item fails the precheck, it returns {:error, :unsuitable_for_download, message}
  #   - However, if the precheck fails in a way that we think can be fixed by using cookies, we retry with cookies
  #     and return the result of that
  # - If the precheck passes but the download fails, it normally returns {:error, :download_failed, message}
  #   - However, there are some errors we can recover from (eg: failure to communicate with SponsorBlock).
  #     In this case, we attempt the download anyway and update the media item with what details we do have.
  #     This case returns {:recovered, updated_media_item, message}
  #   - If we attempt a retry but it fails, we return {:error, :unrecoverable, message}
  # - If there is an unknown error unrelated to the above, we return {:error, :unknown, message}
  # - Finally, if there is no error, we update the media item with the parsed JSON and return {:ok, updated_media_item}
  #
  # Restated, here are the return values for each case:
  # - On success: {:ok, updated_media_item}
  # - On initial failure but successfully recovered: {:recovered, updated_media_item, message}
  # - On error: {:error, error_atom, message} where error_atom is one of:
  #   - `:unsuitable_for_download` if the media item fails the precheck
  #   - `:unrecoverable` if there was an initial failure and the recovery attempt failed
  #   - `:download_failed` for all other yt-dlp-related downloading errors
  #   - `:filtered` when yt-dlp intentionally skipped the media via a configured filter
  #   - `:unknown` for any other errors, including those not related to yt-dlp
  # - If we retry using cookies, all of the above return values apply. The cookie retry
  #   logic is handled transparently as far as the caller is concerned
  defp attempt_download_and_update_for_media_item(media_item, override_opts) do
    output_filepath = FilesystemUtils.generate_metadata_tmpfile(:json)
    media_with_preloads = Repo.preload(media_item, [:metadata, source: :media_profile])
    staging_opts = replacement_staging_options(media_with_preloads, override_opts)

    case DownloadStaging.prepare(media_with_preloads.id, staging_opts) do
      {:ok, staging_directory} ->
        try do
          download_override_opts = maybe_add_staging_directory(override_opts, staging_directory)

          case download_with_client_fallback_chain(
                 media_item.original_url,
                 media_with_preloads,
                 output_filepath,
                 download_override_opts
               ) do
            {:ok, parsed_json} ->
              case MediaWatch.prepare_replacement(media_with_preloads) do
                {:ok, replacement_lease} ->
                  result =
                    transfer_and_update(
                      parsed_json,
                      staging_directory,
                      staging_opts,
                      media_with_preloads,
                      replacement_lease
                    )

                  finish_replacement_lease(replacement_lease)
                  result

                {:error, reason} ->
                  {:error, :watch_hold, watch_hold_message(reason)}
              end

            {:error, :unsuitable_for_download} ->
              message =
                "Media item ##{media_with_preloads.id} isn't suitable for download yet. May be an active or processing live stream"

              Logger.warning(message)

              {:error, :unsuitable_for_download, message}

            {:error, :staging_unavailable, message} ->
              {:error, :staging_unavailable, message}

            {:skipped, message} ->
              Logger.info("yt-dlp filtered out media item ##{media_with_preloads.id}: #{inspect(message)}")

              {:error, :filtered, message}

            {:error, guard_reason, guard_message}
            when guard_reason in [:cancelled, :migration_hold, :insufficient_storage] ->
              {:error, guard_reason, guard_message}

            {:error, message, _exit_code} ->
              Logger.error("yt-dlp download error for media item ##{media_with_preloads.id}: #{inspect(message)}")

              if String.contains?(to_string(message), recoverable_errors()) && is_nil(staging_directory) do
                attempt_recovery_from_error(media_with_preloads, output_filepath, message)
              else
                {:error, :download_failed, message}
              end

            err ->
              Logger.error("Unknown error downloading media item ##{media_with_preloads.id}: #{inspect(err)}")

              {:error, :unknown, "Unknown error: #{inspect(err)}"}
          end
        after
          DownloadStaging.cleanup(staging_directory, staging_opts)
        end

      {:error, reason} ->
        {:error, :staging_unavailable, staging_error_message(reason)}
    end
  end

  defp replacement_staging_options(media_item, override_opts) do
    watched? = MediaWatch.watched?(media_item.id)

    overwriting? =
      override_opts[:overwrite_behaviour] == :force_overwrites &&
        is_binary(media_item.media_filepath) && File.regular?(media_item.media_filepath)

    first_watched_artifact? =
      not is_nil(media_item.watch_download_started_at) and is_nil(media_item.media_downloaded_at) and
        MediaWatch.effective_watch_window_days(media_item.source) > 0

    if watched? or overwriting? or first_watched_artifact? do
      # A watched original must never be replaced from an in-place download.
      [root: DownloadStaging.configured_directory() || DownloadStaging.replacement_directory()]
    else
      []
    end
  end

  defp transfer_and_update(parsed_json, staging_directory, staging_opts, media_with_preloads, :unwatched) do
    first? =
      not is_nil(media_with_preloads.watch_download_started_at) and
        is_nil(media_with_preloads.media_downloaded_at) and
        MediaWatch.effective_watch_window_days(media_with_preloads.source) > 0

    with :ok <- prepare_first_artifact(first?, media_with_preloads, parsed_json, staging_directory),
         {:ok, transferred_json} <- DownloadStaging.transfer(parsed_json, staging_directory, staging_opts),
         :ok <- complete_first_transfer(first?, media_with_preloads, transferred_json) do
      update_media_item_from_parsed_json(media_with_preloads, transferred_json, first_artifact: true)
    else
      {:error, reason} ->
        if first? do
          Logger.error("first artifact staging/transfer failed for item ##{media_with_preloads.id}: #{inspect(reason)}")
          {:error, :artifact_persistence_failed, staging_error_message(reason)}
        else
          {:error, :staging_unavailable, staging_error_message(reason)}
        end
    end
  end

  # A watched replacement moves active files only inside MediaWatch's write
  # reservation and durable intent, so a failure restores the verified original.
  defp transfer_and_update(parsed_json, staging_directory, staging_opts, media_with_preloads, lease) do
    with {:ok, plan} <- DownloadStaging.transfer_plan(parsed_json, staging_directory, staging_opts),
         {:ok, updated} <-
           MediaWatch.commit_replacement(
             lease,
             media_with_preloads,
             plan,
             fn pre_images ->
               DownloadStaging.transfer(
                 parsed_json,
                 staging_directory,
                 Keyword.put(staging_opts, :pre_images, pre_images)
               )
             end,
             fn transferred_json -> update_media_item_from_parsed_json(media_with_preloads, transferred_json) end
           ) do
      {:ok, updated}
    else
      {:error, reason} ->
        Logger.error("watched replacement refused for item ##{media_with_preloads.id}: #{inspect(reason)}")
        {:error, :watch_hold, watch_replacement_message(reason)}
    end
  end

  defp prepare_first_artifact(false, _item, _parsed_json, _stage), do: :ok

  defp prepare_first_artifact(true, item, parsed_json, stage) when is_binary(stage) do
    with {:ok, destinations} <- DownloadStaging.destination_json(parsed_json, stage) do
      FirstArtifact.remember(item, destinations, parsed_json["filepath"])
    end
  end

  defp prepare_first_artifact(true, _item, _parsed_json, _stage), do: {:error, :first_artifact_staging_required}
  defp complete_first_transfer(false, _item, _json), do: :ok
  defp complete_first_transfer(true, item, json), do: FirstArtifact.mark_transferred(item, json)

  defp finish_replacement_lease(:unwatched), do: :ok
  defp finish_replacement_lease(lease), do: MediaWatch.finish_replacement(lease)

  defp watch_hold_message(:watch_guard_unapproved),
    do: "watched originals cannot be replaced until preservation is approved"

  defp watch_hold_message(reason), do: "watched original is protected: #{inspect(reason)}"

  defp watch_replacement_message(reason) do
    "watched replacement stopped and the original was restored: #{inspect(reason)}"
  end

  defp attempt_recovery_from_error(media_with_preloads, output_filepath, error_message) do
    with {:ok, contents} <- File.read(output_filepath),
         {:ok, parsed_json} <- Phoenix.json_library().decode(contents) do
      Logger.info("""
      Recovery from yt-dlp error seems possible. Updating media item ##{media_with_preloads.id}
      with parsed JSON from partial download attempt. Full download will be re-attemted in future
      anyway
      """)

      {:ok, updated_media_item} = update_media_item_from_parsed_json(media_with_preloads, parsed_json)
      {:recovered, updated_media_item, error_message}
    else
      err ->
        Logger.error("Unable to recover error for media item ##{media_with_preloads.id}: #{inspect(err)}")

        {:error, :unrecoverable, error_message}
    end
  end

  @doc false
  def restore_first_artifact(%MediaItem{} = item, parsed_json) do
    update_media_item_from_parsed_json(Repo.preload(item, [:metadata, source: :media_profile]), parsed_json,
      first_artifact: true
    )
  end

  defp update_media_item_from_parsed_json(media_with_preloads, parsed_json, opts \\ []) do
    parsed_attrs =
      parsed_json
      |> MetadataParser.parse_for_media_item()
      # Keep the indexed type that selected this download's path; indexing owns classification.
      |> Map.put(:short_form_content, media_with_preloads.short_form_content)
      |> Map.merge(%{
        # The worker owns the successful completion marker, not metadata or partial recovery.
        culled_at: nil,
        nfo_filepath: determine_nfo_filepath(media_with_preloads, parsed_json),
        metadata: %{
          # IDEA: might be worth kicking off a job for this since thumbnail fetching
          # could fail and I want to handle that in isolation
          metadata_filepath: MetadataFileHelpers.compress_and_store_metadata_for(media_with_preloads, parsed_json),
          thumbnail_filepath: MetadataFileHelpers.download_and_store_thumbnail_for(media_with_preloads)
        }
      })

    # Bytes have arrived, but the artifact is not complete until application
    # postprocessing succeeds. Never start the watch from the transfer time.
    parsed_attrs =
      if opts[:first_artifact] == true and not is_nil(media_with_preloads.watch_download_started_at) and
           is_nil(media_with_preloads.media_downloaded_at) do
        Map.merge(parsed_attrs, %{
          watch_postprocessing_pending: true
        })
      else
        parsed_attrs
      end

    first? =
      opts[:first_artifact] == true and not is_nil(media_with_preloads.watch_download_started_at) and
        is_nil(media_with_preloads.media_downloaded_at)

    if first? and
         (FirstArtifact.pending?(media_with_preloads) or
            MediaWatch.effective_watch_window_days(media_with_preloads.source) > 0) do
      persist_first_artifact(media_with_preloads, parsed_attrs)
    else
      Media.update_media_item(media_with_preloads, parsed_attrs)
    end
  end

  defp persist_first_artifact(item, attrs) do
    case Repo.transaction(fn ->
           case Media.update_media_item(item, attrs) do
             {:ok, updated} -> updated
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.error("first artifact metadata write failed for item ##{item.id}: #{inspect(error)}")
      {:error, :artifact_persistence_failed, "First artifact write failed; retry from protected copy"}
  end

  defp determine_nfo_filepath(media_item, parsed_json) do
    if media_item.source.media_profile.download_nfo do
      filepath = Path.rootname(parsed_json["filepath"]) <> ".nfo"

      NfoBuilder.build_and_store_for_media_item(filepath, parsed_json)
    else
      nil
    end
  end

  defp download_with_options(url, item_with_preloads, output_filepath, override_opts) do
    emit_progress = Keyword.has_key?(override_opts, :progress_handler)
    build_opts = Keyword.put(override_opts, :emit_progress, emit_progress)

    case DownloadOptionBuilder.build(item_with_preloads, build_opts) do
      {:ok, options} ->
        do_download_with_options(url, item_with_preloads, output_filepath, override_opts, options, emit_progress)

      {:error, reason} ->
        {:error, :staging_unavailable, staging_error_message(reason)}
    end
  end

  defp do_download_with_options(url, item_with_preloads, output_filepath, override_opts, options, emit_progress) do
    client = Keyword.get(override_opts, :player_client, item_with_preloads.source.player_client)
    force_use_cookies = Keyword.get(override_opts, :force_use_cookies, false)
    source_uses_cookies = Sources.use_cookies?(item_with_preloads.source, :downloading)
    cookie_compatible? = client not in Source.cookie_incompatible_player_clients()
    should_use_cookies = (force_use_cookies || source_uses_cookies) && cookie_compatible?

    runner_opts =
      [
        output_filepath: output_filepath,
        use_cookies: should_use_cookies
      ] ++ if emit_progress, do: [progress_handler: Keyword.fetch!(override_opts, :progress_handler)], else: []

    if Keyword.get(override_opts, :skip_download_precheck, false) do
      maybe_report_progress(override_opts, %{progress_percent: 0.0, progress_status: "Waiting for transfer to start"})

      download_or_retry_with_cookies(
        url,
        item_with_preloads,
        output_filepath,
        override_opts,
        options,
        runner_opts,
        should_use_cookies
      )
    else
      maybe_report_progress(override_opts, %{progress_percent: 0.0, progress_status: "Prechecking media"})

      case {
        YtDlpMedia.get_downloadable_status(
          url,
          DownloadOptionBuilder.build_youtube_options_for(item_with_preloads, client),
          use_cookies: should_use_cookies
        ),
        should_use_cookies
      } do
        {{:ok, :downloadable}, _} ->
          maybe_report_progress(override_opts, %{
            progress_percent: 0.0,
            progress_status: "Waiting for transfer to start"
          })

          download_or_retry_with_cookies(
            url,
            item_with_preloads,
            output_filepath,
            override_opts,
            options,
            runner_opts,
            should_use_cookies
          )

        {{:ok, :ignorable}, _} ->
          {:error, :unsuitable_for_download}

        {{:error, _message, _exit_code} = err, false} ->
          maybe_retry_with_cookies(url, item_with_preloads, output_filepath, override_opts, err)

        {{:error, message, exit_code}, true} ->
          {:error, message, exit_code}

        {err, _} ->
          err
      end
    end
  end

  # Cookie recovery used to live only on the precheck path. Non-livestream
  # downloads skip that precheck, so age-gate / members-only errors have to
  # be handled here after the actual download attempt as well.
  defp download_or_retry_with_cookies(
         url,
         item_with_preloads,
         output_filepath,
         override_opts,
         options,
         runner_opts,
         should_use_cookies
       ) do
    case {YtDlpMedia.download(url, options, runner_opts), should_use_cookies} do
      {{:error, _message, _exit_code} = err, false} ->
        maybe_retry_with_cookies(url, item_with_preloads, output_filepath, override_opts, err)

      {result, _} ->
        result
    end
  end

  defp maybe_retry_with_cookies(url, item_with_preloads, output_filepath, override_opts, err) do
    {:error, message, _} = err
    source = item_with_preloads.source
    client = Keyword.get(override_opts, :player_client, source.player_client)
    cookie_compatible? = client not in Source.cookie_incompatible_player_clients()
    message_contains_cookie_error = String.contains?(to_string(message), recoverable_cookie_errors())

    if cookie_compatible? && Sources.use_cookies?(source, :error_recovery) && message_contains_cookie_error do
      download_with_options(
        url,
        item_with_preloads,
        output_filepath,
        Keyword.put(override_opts, :force_use_cookies, true)
      )
    else
      err
    end
  end

  defp download_with_client_fallback_chain(url, item_with_preloads, output_filepath, override_opts) do
    chain =
      if Keyword.has_key?(override_opts, :player_client) do
        [Keyword.get(override_opts, :player_client)]
      else
        Source.effective_client_chain(item_with_preloads.source)
      end

    run_client_fallback_chain(url, item_with_preloads, output_filepath, override_opts, chain)
  end

  defp run_client_fallback_chain(url, item_with_preloads, output_filepath, override_opts, [client | remaining_clients]) do
    client_opts = Keyword.put(override_opts, :player_client, client)

    File.rm(output_filepath)

    case download_with_options(url, item_with_preloads, output_filepath, client_opts) do
      {:ok, _parsed_json} = success ->
        success

      {:error, :unsuitable_for_download} = err ->
        err

      {:error, :staging_unavailable, _msg} = err ->
        err

      {:error, message, _exit_code} = err ->
        if remaining_clients != [] and client_fallback_eligible_error?(message) do
          case check_fallback_guards(item_with_preloads, override_opts) do
            {:error, guard_reason, guard_msg} ->
              Logger.warning("Client fallback aborted for media item ##{item_with_preloads.id}: #{guard_msg}")
              {:error, guard_reason, guard_msg}

            :ok ->
              next_client = hd(remaining_clients)

              Logger.warning("""
              yt-dlp client attempt failed for media item ##{item_with_preloads.id} \
              using client #{inspect(client)}: #{inspect(message)}. \
              Falling back to next client: #{inspect(next_client)} (#{length(remaining_clients)} remaining)
              """)

              maybe_report_progress(override_opts, %{
                progress_percent: 0.0,
                progress_status:
                  "Client #{Source.player_client_label(client)} failed; retrying with #{Source.player_client_label(next_client)}"
              })

              run_client_fallback_chain(url, item_with_preloads, output_filepath, override_opts, remaining_clients)
          end
        else
          err
        end

      other ->
        other
    end
  end

  defp run_client_fallback_chain(_url, _item_with_preloads, _output_filepath, _override_opts, []) do
    {:error, "All configured player clients exhausted", 1}
  end

  defp check_fallback_guards(item_with_preloads, override_opts) do
    cond do
      media_item_cancelled_or_missing?(item_with_preloads.id, override_opts) ->
        {:error, :cancelled, "Media download cancelled or media item removed"}

      source_downloads_disabled?(item_with_preloads.source_id) ->
        {:error, :cancelled, "Source media downloads disabled or source disabled"}

      migration_hold_active?() ->
        {:error, :migration_hold, "Database migration in progress"}

      storage_low?(item_with_preloads, override_opts) ->
        {:error, :insufficient_storage, "Insufficient storage space for fallback attempt"}

      true ->
        :ok
    end
  end

  defp media_item_cancelled_or_missing?(item_id, override_opts) do
    case Repo.get(MediaItem, item_id) do
      nil -> true
      %MediaItem{culled_at: culled_at} when not is_nil(culled_at) -> true
      %MediaItem{prevent_download: true} -> true
      _ -> match?({:ok, true}, check_task_cancelled(override_opts))
    end
  end

  defp source_downloads_disabled?(source_id) do
    case Repo.get(Source, source_id) do
      nil -> true
      %Source{download_media: false} -> true
      %Source{enabled: false} -> true
      _ -> false
    end
  end

  defp check_task_cancelled(override_opts) do
    case Keyword.get(override_opts, :job_id) do
      job_id when is_integer(job_id) ->
        case Repo.get(Oban.Job, job_id) do
          nil -> {:ok, true}
          %Oban.Job{state: state} when state in ["cancelled", "discarded"] -> {:ok, true}
          _ -> {:ok, false}
        end

      _ ->
        {:ok, false}
    end
  end

  defp migration_hold_active? do
    cond do
      Code.ensure_loaded?(Pinchflat.Database.PostgresMigration) and
          apply(Pinchflat.Database.PostgresMigration, :pending?, []) ->
        true

      Code.ensure_loaded?(Pinchflat.LegacyMigration) and
          apply(Pinchflat.LegacyMigration, :legacy_migration_pending?, []) ->
        true

      true ->
        false
    end
  end

  defp storage_low?(_item_with_preloads, override_opts) do
    if Code.ensure_loaded?(Pinchflat.Downloading.SpaceProtection) do
      job_id = Keyword.get(override_opts, :job_id)

      case apply(Pinchflat.Downloading.SpaceProtection, :preflight, [job_id]) do
        :ok -> false
        {:snooze, _} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc false
  def client_fallback_eligible_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    non_fallback_indicators = [
      "429",
      "too many requests",
      "rate-limit",
      "private video",
      "this video has been removed",
      "join this channel to get access",
      "members-only",
      "requires payment",
      "not made this video available in your country",
      "requested format is not available",
      "no space left on device",
      "permission denied"
    ]

    has_non_fallback? = Enum.any?(non_fallback_indicators, &String.contains?(msg, &1))

    if has_non_fallback? do
      false
    else
      fallback_indicators = [
        "http error 403",
        "403: forbidden",
        "confirm you’re not a bot",
        "confirm you're not a bot",
        "confirm your age",
        "not available on this client",
        "use --cookies",
        "sign in if you've been granted access",
        "sign in to view this video"
      ]

      Enum.any?(fallback_indicators, &String.contains?(msg, &1))
    end
  end

  def client_fallback_eligible_error?(_), do: false

  defp recoverable_errors do
    [
      "Unable to communicate with SponsorBlock"
    ]
  end

  defp recoverable_cookie_errors do
    [
      "Sign in to confirm",
      "This video is available to this channel's members"
    ]
  end

  defp maybe_report_progress(override_opts, attrs) do
    case Keyword.get(override_opts, :progress_handler) do
      nil -> :ok
      progress_handler -> progress_handler.(attrs)
    end
  end

  defp maybe_add_staging_directory(override_opts, nil), do: override_opts

  defp maybe_add_staging_directory(override_opts, staging_directory) do
    Keyword.put(override_opts, :staging_directory, staging_directory)
  end

  defp staging_error_message(reason) do
    "Download staging is unavailable: #{inspect(reason)}"
  end

  defp persisted_last_error(media_item, message) do
    wrapped_message = StringUtils.wrap_string(message)
    previous_error = media_item.last_error

    if normalized_error(previous_error) == normalized_error(wrapped_message) && is_binary(previous_error) do
      previous_error
    else
      wrapped_message
    end
  end

  defp normalized_error(nil), do: nil

  defp normalized_error(message) do
    message
    |> to_string()
    |> String.trim()
    |> String.replace(~r/^ERROR:\s*/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.downcase()
  end

  defp reload_media_item_for_last_error(media_item) do
    Media.get_media_item!(media_item.id)
  end
end
