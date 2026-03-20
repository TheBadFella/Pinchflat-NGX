defmodule PinchflatWeb.Schemas do
  @moduledoc """
  OpenAPI schemas for the Pinchflat API.
  """

  alias OpenApiSpex.Schema

  defmodule HealthResponse do
    @moduledoc """
    Schema for health check response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      description: "Health check response",
      type: :object,
      properties: %{
        status: %Schema{type: :string, description: "Health status", example: "ok"}
      },
      required: [:status]
    })
  end

  defmodule MediaProfile do
    @moduledoc """
    Schema for a media profile.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MediaProfile",
      description: "Configuration profile for media downloads",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Internal database ID", example: 1},
        name: %Schema{type: :string, description: "Profile name", example: "HD Videos"},
        output_path_template: %Schema{
          type: :string,
          description: "Template for output file paths",
          example: "/{{ source_custom_name }}/{{ upload_yyyy_mm_dd }} {{ title }}/{{ title }} [{{ id }}].{{ ext }}"
        },
        download_subs: %Schema{type: :boolean, description: "Download subtitles", example: false},
        download_auto_subs: %Schema{type: :boolean, description: "Download auto-generated subtitles", example: false},
        embed_subs: %Schema{type: :boolean, description: "Embed subtitles into media file", example: false},
        sub_langs: %Schema{type: :string, description: "Subtitle languages", example: "en"},
        download_thumbnail: %Schema{type: :boolean, description: "Download thumbnail", example: true},
        embed_thumbnail: %Schema{type: :boolean, description: "Embed thumbnail into media file", example: true},
        download_source_images: %Schema{type: :boolean, description: "Download source images", example: false},
        download_metadata: %Schema{type: :boolean, description: "Download metadata", example: true},
        embed_metadata: %Schema{type: :boolean, description: "Embed metadata into media file", example: true},
        download_nfo: %Schema{type: :boolean, description: "Download NFO file", example: false},
        sponsorblock_behaviour: %Schema{
          type: :string,
          enum: [:disabled, :mark, :remove],
          description: "SponsorBlock behavior",
          example: :disabled
        },
        sponsorblock_categories: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "SponsorBlock categories",
          example: ["sponsor", "intro"]
        },
        shorts_behaviour: %Schema{
          type: :string,
          enum: [:include, :exclude, :only],
          description: "Shorts handling behavior",
          example: :include
        },
        livestream_behaviour: %Schema{
          type: :string,
          enum: [:include, :exclude, :only],
          description: "Livestream handling behavior",
          example: :include
        },
        audio_track: %Schema{type: :string, nullable: true, description: "Preferred audio track", example: nil},
        preferred_resolution: %Schema{
          type: :string,
          enum: [:"4320p", :"2160p", :"1440p", :"1080p", :"720p", :"480p", :"360p", :audio],
          description: "Preferred video resolution",
          example: :"1080p"
        },
        media_container: %Schema{type: :string, nullable: true, description: "Media container format", example: "mp4"},
        redownload_delay_days: %Schema{
          type: :integer,
          nullable: true,
          description: "Delay before redownloading",
          example: nil
        },
        inserted_at: %Schema{type: :string, format: :date_time, description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :date_time, description: "Last update timestamp"}
      },
      required: [:id, :name, :output_path_template]
    })
  end

  defmodule Source do
    @moduledoc """
    Schema for a source (channel, playlist, or single video).
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Source",
      description: "A media source (YouTube channel, playlist, or single video)",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Internal database ID", example: 1},
        uuid: %Schema{
          type: :string,
          format: :uuid,
          description: "Public unique identifier",
          example: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        },
        enabled: %Schema{type: :boolean, description: "Whether the source is active", example: true},
        custom_name: %Schema{type: :string, description: "Display name for the source", example: "My Channel"},
        description: %Schema{
          type: :string,
          nullable: true,
          description: "Source description",
          example: "A collection of videos"
        },
        collection_name: %Schema{
          type: :string,
          nullable: true,
          description: "Original collection name",
          example: "Original Channel Name"
        },
        collection_id: %Schema{
          type: :string,
          nullable: true,
          description: "External collection ID",
          example: "UCxxxxxxxxxxxxxxxxxxx"
        },
        collection_type: %Schema{
          type: :string,
          nullable: true,
          enum: [:channel, :playlist, :video],
          description: "Type of collection",
          example: :channel
        },
        original_url: %Schema{
          type: :string,
          description: "Original source URL",
          example: "https://www.youtube.com/channel/UCxxx"
        },
        index_frequency_minutes: %Schema{type: :integer, description: "Indexing frequency in minutes", example: 1440},
        fast_index: %Schema{type: :boolean, description: "Use fast indexing", example: false},
        download_media: %Schema{type: :boolean, description: "Download media items", example: true},
        last_indexed_at: %Schema{
          type: :string,
          format: :date_time,
          nullable: true,
          description: "Last indexing timestamp"
        },
        download_cutoff_date: %Schema{
          type: :string,
          format: :date,
          nullable: true,
          description: "Only download media after this date"
        },
        retention_period_days: %Schema{
          type: :integer,
          nullable: true,
          description: "Delete media older than this many days"
        },
        title_filter_regex: %Schema{type: :string, nullable: true, description: "Regex to filter media titles"},
        min_duration_seconds: %Schema{type: :integer, nullable: true, description: "Minimum media duration"},
        max_duration_seconds: %Schema{type: :integer, nullable: true, description: "Maximum media duration"},
        series_directory: %Schema{type: :string, nullable: true, description: "Directory for series organization"},
        nfo_filepath: %Schema{type: :string, nullable: true, description: "Path to NFO file"},
        poster_filepath: %Schema{type: :string, nullable: true, description: "Path to poster image"},
        fanart_filepath: %Schema{type: :string, nullable: true, description: "Path to fanart image"},
        banner_filepath: %Schema{type: :string, nullable: true, description: "Path to banner image"},
        media_profile_id: %Schema{type: :integer, description: "ID of associated media profile"},
        media_profile: %Schema{
          allOf: [MediaProfile],
          description: "Associated media profile"
        },
        inserted_at: %Schema{type: :string, format: :date_time, description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :date_time, description: "Last update timestamp"}
      },
      required: [:id, :uuid, :custom_name, :collection_name, :collection_id, :collection_type]
    })
  end

  defmodule MediaItem do
    @moduledoc """
    Schema for a media item.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MediaItem",
      description: "A media item that has been downloaded",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Internal database ID", example: 1},
        uuid: %Schema{
          type: :string,
          format: :uuid,
          description: "Unique identifier",
          example: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        },
        title: %Schema{type: :string, description: "Media title", example: "My Video Title"},
        media_id: %Schema{type: :string, description: "External media ID", example: "youtube_video_id"},
        source_id: %Schema{type: :integer, description: "ID of the source this media belongs to", example: 1},
        source: %Schema{
          allOf: [Source],
          description: "The source this media belongs to"
        },
        uploaded_at: %Schema{
          type: :string,
          format: :date_time,
          description: "When the media was originally uploaded",
          example: "2024-01-01T12:00:00Z"
        },
        media_downloaded_at: %Schema{
          type: :string,
          format: :date_time,
          nullable: true,
          description: "When the media was downloaded",
          example: "2024-01-02T10:30:00Z"
        },
        media_filepath: %Schema{
          type: :string,
          nullable: true,
          description: "Path to the downloaded media file",
          example: "/downloads/video.mp4"
        },
        thumbnail_filepath: %Schema{
          type: :string,
          nullable: true,
          description: "Path to the thumbnail file",
          example: "/downloads/thumbnail.jpg"
        },
        metadata_filepath: %Schema{
          type: :string,
          nullable: true,
          description: "Path to the metadata file",
          example: "/downloads/metadata.json"
        },
        nfo_filepath: %Schema{
          type: :string,
          nullable: true,
          description: "Path to the NFO file",
          example: "/downloads/video.nfo"
        },
        subtitle_filepaths: %Schema{
          type: :array,
          nullable: true,
          items: %Schema{type: :string},
          description: "Paths to subtitle files",
          example: ["/downloads/subtitle_en.srt", "/downloads/subtitle_de.srt"]
        },
        inserted_at: %Schema{type: :string, format: :date_time, description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :date_time, description: "Last update timestamp"}
      },
      required: [:id, :uuid, :title, :media_id, :source_id]
    })
  end

  defmodule RecentDownloadsResponse do
    @moduledoc """
    Schema for recent downloads response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecentDownloadsResponse",
      description: "Response containing a list of recently downloaded media items",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: MediaItem,
          description: "List of recently downloaded media items"
        }
      },
      required: [:data]
    })
  end

  defmodule SourcesListResponse do
    @moduledoc """
    Schema for listing sources response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SourcesListResponse",
      description: "Response containing a list of sources",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: Source,
          description: "List of sources"
        }
      },
      required: [:data]
    })
  end

  defmodule CreateSourceRequest do
    @moduledoc """
    Schema for creating a new source.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CreateSourceRequest",
      description: "Request body for creating a new source",
      type: :object,
      properties: %{
        source: %Schema{
          type: :object,
          properties: %{
            original_url: %Schema{
              type: :string,
              description: "YouTube channel, playlist, or single video URL (required for creation)",
              example: "https://www.youtube.com/channel/UCxxx"
            },
            media_profile_id: %Schema{
              type: :integer,
              description: "Media profile ID (required for creation)",
              example: 1
            },
            custom_name: %Schema{
              type: :string,
              description: "Custom display name (optional, defaults to collection name)"
            },
            description: %Schema{type: :string, description: "Source description"},
            enabled: %Schema{type: :boolean, description: "Whether the source is active", default: true},
            download_media: %Schema{type: :boolean, description: "Download media items", default: true},
            fast_index: %Schema{type: :boolean, description: "Use fast indexing", default: false},
            index_frequency_minutes: %Schema{
              type: :integer,
              description: "Indexing frequency in minutes",
              default: 1440
            },
            download_cutoff_date: %Schema{
              type: :string,
              format: :date,
              description: "Only download media after this date (YYYY-MM-DD)"
            },
            retention_period_days: %Schema{
              type: :integer,
              description: "Delete media older than this many days"
            },
            title_filter_regex: %Schema{type: :string, description: "Regex to filter media titles"},
            min_duration_seconds: %Schema{type: :integer, description: "Minimum media duration in seconds"},
            max_duration_seconds: %Schema{type: :integer, description: "Maximum media duration in seconds"},
            output_path_template_override: %Schema{
              type: :string,
              description: "Override the media profile's output path template"
            }
          },
          required: [:original_url, :media_profile_id]
        }
      },
      required: [:source]
    })
  end

  defmodule UpdateSourceRequest do
    @moduledoc """
    Schema for updating an existing source.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UpdateSourceRequest",
      description: "Request body for updating a source",
      type: :object,
      properties: %{
        source: %Schema{
          type: :object,
          properties: %{
            custom_name: %Schema{type: :string, description: "Custom display name"},
            description: %Schema{type: :string, description: "Source description"},
            enabled: %Schema{type: :boolean, description: "Whether the source is active"},
            download_media: %Schema{type: :boolean, description: "Download media items"},
            fast_index: %Schema{type: :boolean, description: "Use fast indexing"},
            index_frequency_minutes: %Schema{type: :integer, description: "Indexing frequency in minutes"},
            download_cutoff_date: %Schema{
              type: :string,
              format: :date,
              description: "Only download media after this date"
            },
            retention_period_days: %Schema{type: :integer, description: "Delete media older than this many days"},
            title_filter_regex: %Schema{type: :string, description: "Regex to filter media titles"},
            min_duration_seconds: %Schema{type: :integer, description: "Minimum media duration in seconds"},
            max_duration_seconds: %Schema{type: :integer, description: "Maximum media duration in seconds"},
            output_path_template_override: %Schema{
              type: :string,
              description: "Override the media profile's output path template"
            },
            media_profile_id: %Schema{type: :integer, description: "Media profile ID"}
          }
        }
      },
      required: [:source]
    })
  end

  defmodule MediaProfilesListResponse do
    @moduledoc """
    Schema for listing media profiles response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MediaProfilesListResponse",
      description: "Response containing a list of media profiles",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: MediaProfile,
          description: "List of media profiles"
        }
      },
      required: [:data]
    })
  end

  defmodule CreateMediaProfileRequest do
    @moduledoc """
    Schema for creating a new media profile.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CreateMediaProfileRequest",
      description: "Request body for creating a new media profile",
      type: :object,
      properties: %{
        media_profile: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Profile name (required)", example: "HD Videos"},
            output_path_template: %Schema{
              type: :string,
              description: "Template for output file paths (required)",
              example: "/{{ source_custom_name }}/{{ title }} [{{ id }}].{{ ext }}"
            },
            download_subs: %Schema{type: :boolean, description: "Download subtitles", default: false},
            download_auto_subs: %Schema{
              type: :boolean,
              description: "Download auto-generated subtitles",
              default: false
            },
            embed_subs: %Schema{type: :boolean, description: "Embed subtitles into media file", default: false},
            sub_langs: %Schema{type: :string, description: "Subtitle languages", default: "en"},
            download_thumbnail: %Schema{type: :boolean, description: "Download thumbnail", default: true},
            embed_thumbnail: %Schema{type: :boolean, description: "Embed thumbnail into media file", default: true},
            download_source_images: %Schema{type: :boolean, description: "Download source images", default: false},
            download_metadata: %Schema{type: :boolean, description: "Download metadata", default: true},
            embed_metadata: %Schema{type: :boolean, description: "Embed metadata into media file", default: true},
            download_nfo: %Schema{type: :boolean, description: "Download NFO file", default: false},
            sponsorblock_behaviour: %Schema{
              type: :string,
              enum: [:disabled, :mark, :remove],
              description: "SponsorBlock behavior",
              default: :disabled
            },
            sponsorblock_categories: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "SponsorBlock categories",
              default: []
            },
            shorts_behaviour: %Schema{
              type: :string,
              enum: [:include, :exclude, :only],
              description: "Shorts handling behavior",
              default: :include
            },
            livestream_behaviour: %Schema{
              type: :string,
              enum: [:include, :exclude, :only],
              description: "Livestream handling behavior",
              default: :include
            },
            audio_track: %Schema{type: :string, description: "Preferred audio track"},
            preferred_resolution: %Schema{
              type: :string,
              enum: [:"4320p", :"2160p", :"1440p", :"1080p", :"720p", :"480p", :"360p", :audio],
              description: "Preferred video resolution",
              default: :"1080p"
            },
            media_container: %Schema{type: :string, description: "Media container format", default: "mp4"},
            redownload_delay_days: %Schema{type: :integer, description: "Delay before redownloading"}
          },
          required: [:name, :output_path_template]
        }
      },
      required: [:media_profile]
    })
  end

  defmodule UpdateMediaProfileRequest do
    @moduledoc """
    Schema for updating an existing media profile.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UpdateMediaProfileRequest",
      description: "Request body for updating a media profile",
      type: :object,
      properties: %{
        media_profile: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Profile name"},
            output_path_template: %Schema{type: :string, description: "Template for output file paths"},
            download_subs: %Schema{type: :boolean, description: "Download subtitles"},
            download_auto_subs: %Schema{type: :boolean, description: "Download auto-generated subtitles"},
            embed_subs: %Schema{type: :boolean, description: "Embed subtitles into media file"},
            sub_langs: %Schema{type: :string, description: "Subtitle languages"},
            download_thumbnail: %Schema{type: :boolean, description: "Download thumbnail"},
            embed_thumbnail: %Schema{type: :boolean, description: "Embed thumbnail into media file"},
            download_source_images: %Schema{type: :boolean, description: "Download source images"},
            download_metadata: %Schema{type: :boolean, description: "Download metadata"},
            embed_metadata: %Schema{type: :boolean, description: "Embed metadata into media file"},
            download_nfo: %Schema{type: :boolean, description: "Download NFO file"},
            sponsorblock_behaviour: %Schema{
              type: :string,
              enum: [:disabled, :mark, :remove],
              description: "SponsorBlock behavior"
            },
            sponsorblock_categories: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "SponsorBlock categories"
            },
            shorts_behaviour: %Schema{
              type: :string,
              enum: [:include, :exclude, :only],
              description: "Shorts handling behavior"
            },
            livestream_behaviour: %Schema{
              type: :string,
              enum: [:include, :exclude, :only],
              description: "Livestream handling behavior"
            },
            audio_track: %Schema{type: :string, description: "Preferred audio track"},
            preferred_resolution: %Schema{
              type: :string,
              enum: [:"4320p", :"2160p", :"1440p", :"1080p", :"720p", :"480p", :"360p", :audio],
              description: "Preferred video resolution"
            },
            media_container: %Schema{type: :string, description: "Media container format"},
            redownload_delay_days: %Schema{type: :integer, description: "Delay before redownloading"}
          }
        }
      },
      required: [:media_profile]
    })
  end

  defmodule MediaItemsListResponse do
    @moduledoc """
    Schema for listing media items response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MediaItemsListResponse",
      description: "Response containing a list of media items",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: MediaItem,
          description: "List of media items"
        }
      },
      required: [:data]
    })
  end

  defmodule SearchResponse do
    @moduledoc """
    Schema for search response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SearchResponse",
      description: "Response containing search results",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: MediaItem,
          description: "List of media items matching the search"
        },
        query: %Schema{
          type: :string,
          description: "The search query that was executed"
        }
      },
      required: [:data, :query]
    })
  end

  defmodule Task do
    @moduledoc """
    Schema for a task (Oban job).
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Task",
      description: "A background task/job",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Task ID", example: 1},
        job_id: %Schema{type: :integer, description: "Oban job ID", example: 123},
        source_id: %Schema{type: :integer, description: "Associated source ID"},
        media_item_id: %Schema{type: :integer, description: "Associated media item ID"},
        worker: %Schema{
          type: :string,
          description: "Worker module name",
          example: "Pinchflat.Downloading.MediaDownloadWorker"
        },
        state: %Schema{
          type: :string,
          enum: [:available, :scheduled, :executing, :retryable, :completed, :discarded, :cancelled],
          description: "Job state"
        },
        args: %Schema{type: :object, description: "Job arguments"},
        errors: %Schema{
          type: :array,
          items: %Schema{type: :object},
          description: "Job errors"
        },
        attempt: %Schema{type: :integer, description: "Current attempt number"},
        max_attempts: %Schema{type: :integer, description: "Maximum attempts"},
        inserted_at: %Schema{type: :string, format: :date_time, description: "Creation timestamp"},
        scheduled_at: %Schema{type: :string, format: :date_time, description: "Scheduled execution time"},
        attempted_at: %Schema{type: :string, format: :date_time, description: "Last attempt time"},
        completed_at: %Schema{type: :string, format: :date_time, description: "Completion time"}
      },
      required: [:id, :job_id, :worker, :state]
    })
  end

  defmodule TasksListResponse do
    @moduledoc """
    Schema for listing tasks response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TasksListResponse",
      description: "Response containing a list of tasks",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: Task,
          description: "List of tasks"
        }
      },
      required: [:data]
    })
  end

  defmodule StatsResponse do
    @moduledoc """
    Schema for statistics response.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StatsResponse",
      description: "Response containing application statistics",
      type: :object,
      properties: %{
        media_profile_count: %Schema{type: :integer, description: "Number of media profiles", example: 5},
        source_count: %Schema{type: :integer, description: "Number of sources", example: 12},
        media_item_count: %Schema{type: :integer, description: "Number of downloaded media items", example: 1234},
        total_download_size_bytes: %Schema{
          type: :integer,
          description: "Total size of downloaded media in bytes",
          example: 104_857_600
        }
      },
      required: [:media_profile_count, :source_count, :media_item_count, :total_download_size_bytes]
    })
  end

  defmodule ActionResponse do
    @moduledoc """
    Schema for action response (e.g., triggering downloads).
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ActionResponse",
      description: "Response from triggering an action",
      type: :object,
      properties: %{
        message: %Schema{type: :string, description: "Success message", example: "Action completed successfully"}
      },
      required: [:message]
    })
  end

  defmodule NotFoundResponse do
    @moduledoc """
    Schema for 404 not found responses.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NotFoundResponse",
      description: "Resource not found error",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Error message", example: "Not found"}
      }
    })
  end

  defmodule ValidationErrorResponse do
    @moduledoc """
    Schema for 422 validation error responses.
    """

    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ValidationErrorResponse",
      description: "Validation error response",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          description: "Validation errors by field",
          additionalProperties: %Schema{
            type: :array,
            items: %Schema{type: :string}
          },
          example: %{"name" => ["can't be blank"]}
        }
      },
      required: [:errors]
    })
  end
end
