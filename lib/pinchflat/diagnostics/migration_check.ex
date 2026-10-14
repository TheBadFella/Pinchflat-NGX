defmodule Pinchflat.Diagnostics.MigrationCheck do
  @moduledoc """
  Read-only diagnostic scanner for existing Pinchflat-NGX installations.

  Audits:
  - Database schema & migration history
  - Source naming configuration & refresh exposure
  - Unavailable metadata loss & fallback indicators (including empty `{}` payloads)
  - Media file references & physical storage accessibility (distinguishing EACCES from ENOENT)
  - Artwork presence (UI posters & custom posters)
  - Mount configurations & path mismatches
  - Notification command settings with credential redaction

  All operations in this module are strictly read-only and never mutate
  database records, files, background jobs, or queues.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Pinchflat.LegacyMigration
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.CustomPoster
  alias Pinchflat.Sources.Source

  @expected_hardening_migrations [
    {20_261_005_120_000, "20261005120000 (preserve migrated source names)"},
    {20_261_005_130_000, "20261005130000 (migration review queue state)"},
    {20_261_005_140_000, "20261005140000 (migration artwork repairs)"}
  ]

  @doc """
  Runs a complete read-only diagnostic scan across the installation.

  Returns a map containing summary statistics and a structured list of classified findings.
  """
  def scan do
    schema_findings = scan_schema()
    naming_findings = scan_source_naming()
    metadata_findings = scan_unavailable_metadata()
    mount_findings = scan_mounts()
    media_findings = scan_media_files()
    artwork_findings = scan_artwork()
    notification_findings = scan_notifications()

    all_findings =
      schema_findings ++
        naming_findings ++
        metadata_findings ++
        mount_findings ++
        media_findings ++
        artwork_findings ++
        notification_findings

    sources_count = Repo.aggregate(Source, :count, :id) || 0
    unlocked_count = Enum.count(naming_findings, &(&1.category == :source_naming))
    missing_media_count = Enum.count(media_findings, &(&1.category == :media_files and &1.classification == :proved))
    missing_art_count = Enum.count(artwork_findings, &(&1.category == :artwork))

    summary = %{
      total_sources: sources_count,
      unlocked_sources_count: unlocked_count,
      missing_media_count: missing_media_count,
      missing_artwork_count: missing_art_count,
      findings_count: length(all_findings),
      status: if(all_findings == [], do: :clean, else: :issues_found)
    }

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      summary: summary,
      findings: all_findings
    }
  end

  @doc """
  Audits applied database schema migrations.
  """
  def scan_schema do
    try do
      versions = Ecto.Migrator.migrated_versions(Repo)
      max_version = Enum.max(versions, fn -> 0 end)

      missing =
        Enum.filter(@expected_hardening_migrations, fn {ver, _desc} ->
          ver not in versions
        end)

      findings = []

      if missing != [] do
        missing_descs = Enum.map_join(missing, ", ", fn {_, desc} -> desc end)

        [
          %{
            category: :schema,
            classification: :proved,
            entity_type: :schema,
            entity_id: "migrations",
            description: "Database is missing expected hardening migration(s): #{missing_descs}.",
            details: %{
              max_version: max_version,
              migrated_count: length(versions),
              missing_migrations: Enum.map(missing, &elem(&1, 0))
            }
          }
          | findings
        ]
      else
        findings
      end
    rescue
      e ->
        [
          %{
            category: :schema,
            classification: :proved,
            entity_type: :schema,
            entity_id: "migrations",
            description: "Could not query schema migration versions: #{inspect(e)}",
            details: %{error: inspect(e)}
          }
        ]
    end
  end

  @doc """
  Audits source naming settings and identifies sources exposed to automated refresh.
  """
  def scan_source_naming do
    sources = Repo.all(Source)

    Enum.flat_map(sources, fn source ->
      if source.custom_name_locked do
        []
      else
        [
          %{
            category: :source_naming,
            classification: :ambiguous,
            entity_type: :source,
            entity_id: source.id,
            description:
              "Source ##{source.id} ('#{source.custom_name}') has custom_name_locked disabled; automated metadata refresh may overwrite custom names.",
            details: %{
              source_id: source.id,
              custom_name: source.custom_name,
              custom_name_locked: false,
              collection_type: source.collection_type
            }
          }
        ]
      end
    end)
  end

  @doc """
  Audits sources for empty or missing metadata records caused by unavailable media fallbacks,
  including detecting empty `{}` payload damage.
  """
  def scan_unavailable_metadata do
    sources = Repo.all(Source) |> Repo.preload(:metadata)

    Enum.flat_map(sources, fn source ->
      cond do
        is_nil(source.metadata) ->
          [
            %{
              category: :unavailable_metadata,
              classification: :ambiguous,
              entity_type: :source,
              entity_id: source.id,
              description: "Source ##{source.id} ('#{source.custom_name}') has no associated source_metadata record.",
              details: %{source_id: source.id, reason: :missing_metadata_record}
            }
          ]

        is_nil(source.metadata.metadata_filepath) ->
          [
            %{
              category: :unavailable_metadata,
              classification: :ambiguous,
              entity_type: :source,
              entity_id: source.id,
              description: "Source ##{source.id} metadata_filepath is nil (possible unavailable media fallback).",
              details: %{source_id: source.id, reason: :nil_metadata_filepath}
            }
          ]

        is_binary(source.metadata.metadata_filepath) and File.exists?(source.metadata.metadata_filepath) ->
          case MetadataFileHelpers.read_compressed_metadata(source.metadata.metadata_filepath) do
            {:ok, metadata_map} when is_map(metadata_map) and map_size(metadata_map) == 0 ->
              [
                %{
                  category: :unavailable_metadata,
                  classification: :proved,
                  entity_type: :source,
                  entity_id: source.id,
                  description:
                    "Source ##{source.id} metadata file contains empty fallback '{}' from unavailable media handling.",
                  details: %{
                    source_id: source.id,
                    filepath: source.metadata.metadata_filepath,
                    reason: :empty_fallback_json
                  }
                }
              ]

            _ ->
              []
          end

        true ->
          []
      end
    end)
  end

  @doc """
  Audits required filesystem mount directories, testing usable access.
  """
  def scan_mounts do
    media_dir = Application.get_env(:pinchflat, :media_directory, "/downloads")
    config_dir = System.get_env("CONFIG_PATH", "/config")

    findings = []

    findings =
      case File.ls(media_dir) do
        {:ok, _} ->
          findings

        {:error, :enoent} ->
          [
            %{
              category: :mounts,
              classification: :proved,
              entity_type: :mount,
              entity_id: "downloads",
              description: "Media storage mount '#{media_dir}' is missing or not a directory.",
              details: %{path: media_dir, reason: :enoent}
            }
            | findings
          ]

        {:error, :eacces} ->
          [
            %{
              category: :mounts,
              classification: :ambiguous,
              entity_type: :mount,
              entity_id: "downloads",
              description: "Media storage mount '#{media_dir}' cannot be listed due to permission denial (EACCES).",
              details: %{path: media_dir, reason: :eacces}
            }
            | findings
          ]

        {:error, reason} ->
          [
            %{
              category: :mounts,
              classification: :ambiguous,
              entity_type: :mount,
              entity_id: "downloads",
              description: "Media storage mount '#{media_dir}' error: #{inspect(reason)}",
              details: %{path: media_dir, reason: reason}
            }
            | findings
          ]
      end

    case File.ls(config_dir) do
      {:ok, _} ->
        findings

      {:error, :enoent} ->
        [
          %{
            category: :mounts,
            classification: :proved,
            entity_type: :mount,
            entity_id: "config",
            description: "Config storage mount '#{config_dir}' is missing or not a directory.",
            details: %{path: config_dir, reason: :enoent}
          }
          | findings
        ]

      {:error, :eacces} ->
        [
          %{
            category: :mounts,
            classification: :ambiguous,
            entity_type: :mount,
            entity_id: "config",
            description: "Config storage mount '#{config_dir}' cannot be listed due to permission denial (EACCES).",
            details: %{path: config_dir, reason: :eacces}
          }
          | findings
        ]

      {:error, reason} ->
        [
          %{
            category: :mounts,
            classification: :ambiguous,
            entity_type: :mount,
            entity_id: "config",
            description: "Config storage mount '#{config_dir}' error: #{inspect(reason)}",
            details: %{path: config_dir, reason: reason}
          }
          | findings
        ]
    end
  end

  @doc """
  Audits physical media file accessibility on disk.
  Detects records whose paths were cleared by historical sync damage, and distinguishes
  permission denial (EACCES) from genuine missing files (ENOENT).
  """
  def scan_media_files do
    media_dir = Application.get_env(:pinchflat, :media_directory, "/downloads")

    media_mounted? =
      case File.ls(media_dir) do
        {:ok, _} -> true
        _ -> false
      end

    # Query all records marked downloaded OR having a media_filepath populated
    items =
      Repo.all(
        from mi in MediaItem,
          where: not is_nil(mi.media_downloaded_at) or not is_nil(mi.media_filepath)
      )

    Enum.flat_map(items, fn item ->
      filepath = item.media_filepath

      cond do
        is_nil(filepath) or filepath == "" ->
          [
            %{
              category: :media_files,
              classification: :proved,
              entity_type: :media_item,
              entity_id: item.id,
              description: "MediaItem ##{item.id} ('#{item.title}') is marked downloaded but has no media_filepath.",
              details: %{item_id: item.id, title: item.title, reason: :cleared_filepath}
            }
          ]

        not media_mounted? and String.starts_with?(filepath, media_dir) ->
          [
            %{
              category: :media_files,
              classification: :ambiguous,
              entity_type: :media_item,
              entity_id: item.id,
              description: "MediaItem ##{item.id} file is inaccessible because #{media_dir} is not mounted.",
              details: %{item_id: item.id, filepath: filepath, reason: :mount_missing}
            }
          ]

        true ->
          case File.stat(filepath) do
            {:ok, _} ->
              []

            {:error, :eacces} ->
              [
                %{
                  category: :media_files,
                  classification: :ambiguous,
                  entity_type: :media_item,
                  entity_id: item.id,
                  description:
                    "MediaItem ##{item.id} file at '#{filepath}' cannot be accessed due to permission denial (EACCES).",
                  details: %{item_id: item.id, title: item.title, filepath: filepath, reason: :eacces}
                }
              ]

            {:error, :enoent} ->
              parent_dir = Path.dirname(filepath)

              case File.stat(parent_dir) do
                {:error, :eacces} ->
                  [
                    %{
                      category: :media_files,
                      classification: :ambiguous,
                      entity_type: :media_item,
                      entity_id: item.id,
                      description:
                        "MediaItem ##{item.id} parent directory '#{parent_dir}' cannot be accessed due to permission denial (EACCES).",
                      details: %{item_id: item.id, title: item.title, filepath: filepath, reason: :eacces}
                    }
                  ]

                _ ->
                  [
                    %{
                      category: :media_files,
                      classification: :proved,
                      entity_type: :media_item,
                      entity_id: item.id,
                      description: "MediaItem ##{item.id} file does not exist at recorded path '#{filepath}'.",
                      details: %{item_id: item.id, title: item.title, filepath: filepath, reason: :enoent}
                    }
                  ]
              end

            {:error, other_reason} ->
              [
                %{
                  category: :media_files,
                  classification: :ambiguous,
                  entity_type: :media_item,
                  entity_id: item.id,
                  description:
                    "MediaItem ##{item.id} file check encountered error: #{inspect(other_reason)} at '#{filepath}'.",
                  details: %{item_id: item.id, title: item.title, filepath: filepath, reason: other_reason}
                }
              ]
          end
      end
    end)
  end

  @doc """
  Audits channel artwork and custom posters on disk.
  """
  def scan_artwork do
    channel_sources =
      Source
      |> where([s], s.collection_type == :channel)
      |> Repo.all()
      |> Repo.preload([:metadata, :media_profile])

    Enum.flat_map(channel_sources, fn source ->
      findings = []

      findings =
        case source.custom_poster_filename do
          filename when is_binary(filename) and filename != "" ->
            case CustomPoster.filepath(source) do
              path when is_binary(path) ->
                if File.exists?(path) do
                  findings
                else
                  [
                    %{
                      category: :artwork,
                      classification: :proved,
                      entity_type: :source,
                      entity_id: source.id,
                      description: "Source ##{source.id} custom poster file is missing from disk at '#{path}'.",
                      details: %{source_id: source.id, filename: filename, filepath: path}
                    }
                    | findings
                  ]
                end

              _ ->
                findings
            end

          _ ->
            findings
        end

      if LegacyMigration.channel_artwork_missing?(source) do
        [
          %{
            category: :artwork,
            classification: :proved,
            entity_type: :source,
            entity_id: source.id,
            description: "Channel ##{source.id} ('#{source.custom_name}') is missing UI poster artwork.",
            details: %{source_id: source.id, custom_name: source.custom_name}
          }
          | findings
        ]
      else
        findings
      end
    end)
  end

  @doc """
  Audits notification settings for potential command and CLI configuration issues.
  Redacts sensitive authentication tokens and credentials in exportable reports.
  """
  def scan_notifications do
    case Settings.get(:apprise_server) do
      {:ok, server} when is_binary(server) and server != "" ->
        redacted_server = redact_url(server)

        base_url_info =
          case Settings.get(:external_base_url) do
            {:ok, base_url} when is_binary(base_url) and base_url != "" ->
              "linked notifications enabled with external_base_url"

            _ ->
              "external_base_url unset (links omitted from notifications)"
          end

        [
          %{
            category: :notifications,
            classification: :ambiguous,
            entity_type: :setting,
            entity_id: "apprise_server",
            description: "Notification server is configured (#{redacted_server}); #{base_url_info}.",
            details: %{
              apprise_server: redacted_server,
              linked_notifications:
                match?({:ok, val} when is_binary(val) and val != "", Settings.get(:external_base_url))
            }
          }
        ]

      _ ->
        []
    end
  end

  @doc """
  Redacts sensitive passwords, tokens, API keys, and secret webhook identifiers
  from notification service URLs and URIs.
  """
  def redact_url(nil), do: nil
  def redact_url(""), do: ""

  def redact_url(url) when is_binary(url) do
    url
    |> redact_uri_userinfo()
    |> redact_query_secrets()
    |> redact_path_secrets()
  end

  defp redact_uri_userinfo(url) do
    Regex.replace(~r/:\/\/([^:]+):([^@]+)@/, url, "://\\1:[REDACTED]@")
  end

  defp redact_query_secrets(url) do
    Regex.replace(~r/([?&][^=]+)=([^&]*)/, url, fn match, key, _val ->
      param_name = String.downcase(key)

      if String.contains?(param_name, [
           "token",
           "secret",
           "key",
           "pass",
           "auth",
           "credential",
           "sign",
           "webhook"
         ]) do
        "#{key}=[REDACTED]"
      else
        match
      end
    end)
  end

  defp redact_path_secrets(url) do
    cond do
      String.starts_with?(url, ["tgram://", "telegram://"]) ->
        Regex.replace(~r/^(tgram|telegram):\/\/[^\/]+/i, url, "\\1://[REDACTED]")

      String.starts_with?(url, "discord://") ->
        Regex.replace(~r/^(discord:\/\/[^\/]+\/)[^\/]+/i, url, "\\1[REDACTED]")

      String.starts_with?(url, "slack://") ->
        Regex.replace(~r/^(slack:\/\/[^\/]+\/)[^\/]+/i, url, "\\1[REDACTED]")

      true ->
        url
    end
  end
end
