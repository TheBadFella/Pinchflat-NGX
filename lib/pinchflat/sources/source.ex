defmodule Pinchflat.Sources.Source do
  @moduledoc """
  The Source schema.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Pinchflat.Utils.ChangesetUtils

  alias __MODULE__
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Metadata.SourceMetadata
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task

  @player_client_options [
    {"Web", :web},
    {"Web Safari", :web_safari},
    {"Web Embedded", :web_embedded},
    {"Web Music", :web_music},
    {"Web Creator", :web_creator},
    {"Mobile Web", :mweb},
    {"iOS", :ios},
    {"VisionOS", :visionos},
    {"Android", :android},
    {"Android VR", :android_vr},
    {"TV", :tv},
    {"TV Downgraded", :tv_downgraded},
    {"TV Simply", :tv_simply}
  ]

  @player_client_values Keyword.values(@player_client_options)
  @cookie_incompatible_player_clients [:android, :ios, :tv_simply]

  @source_type_options [
    {"Automatic", :automatic},
    {"Channel", :channel},
    {"Playlist", :playlist},
    {"Video", :video}
  ]

  @allowed_fields ~w(
    enabled
    collection_name
    collection_id
    collection_type
    source_type
    custom_name
    custom_name_locked
    description
    description_locked
    nfo_filepath
    poster_filepath
    fanart_filepath
    banner_filepath
    series_directory
    index_frequency_minutes
    fast_index
    cookie_behaviour
    player_client
    player_client_fallbacks
    selection_mode
    download_media
    download_public_media
    download_members_only_media
    last_indexed_at
    original_url
    download_cutoff_date
    index_cutoff_date
    retention_period_days
    title_filter_regex
    download_subdirectory
    media_profile_id
    output_path_template_override
    output_path_template_shorts_override
    marked_for_deletion_at
    min_duration_seconds
    max_duration_seconds
  )a

  # Expensive API calls are made when a source is inserted/updated so
  # we want to ensure that the source is valid before making the call.
  # This way, we check that the other attributes are valid before ensuring
  # that all fields are valid. This is still only one DB insert but it's
  # a two-stage validation process to fail fast before the API call.
  @initially_required_fields ~w(
    index_frequency_minutes
    fast_index
    download_media
    original_url
    media_profile_id
  )a

  @pre_insert_required_fields @initially_required_fields ++
                                ~w(
                                  uuid
                                  custom_name
                                  collection_name
                                  collection_id
                                  collection_type
                                )a

  schema "sources" do
    field :enabled, :boolean, default: true
    # This is _not_ used as the primary key or internally in the database
    # relations. This is only used to prevent an enumeration attack on the streaming
    # and RSS feed endpoints since those _must_ be public (ie: no basic auth)
    field :uuid, Ecto.UUID

    field :custom_name, :string
    field :custom_name_locked, :boolean, default: false
    field :description, :string
    field :description_locked, :boolean, default: false
    field :collection_name, :string
    field :collection_id, :string
    field :collection_type, Ecto.Enum, values: [:channel, :playlist, :video]
    field :source_type, Ecto.Enum, values: [:automatic, :channel, :playlist, :video], virtual: true, default: :automatic
    field :index_frequency_minutes, :integer, default: 60 * 24
    field :fast_index, :boolean, default: false
    field :cookie_behaviour, Ecto.Enum, values: [:disabled, :when_needed, :all_operations], default: :disabled
    field :player_client, Ecto.Enum, values: @player_client_values
    field :player_client_fallbacks, {:array, :string}, default: []
    field :selection_mode, Ecto.Enum, values: [:all, :manual], default: :all
    field :download_media, :boolean, default: true
    # Keep both policies enabled by default so existing sources retain their
    # current behavior after the policy fields are introduced.
    field :download_public_media, :boolean, default: true
    field :download_members_only_media, :boolean, default: true
    field :last_indexed_at, :utc_datetime
    # Only download media items that were published after this date
    field :download_cutoff_date, :date
    # Stop indexing a channel once it reaches media published before this date.
    # Only applied to YouTube channels — their tab listings are newest-first,
    # which is what makes an early abort on an old video safe. Playlists are
    # ordered arbitrarily so this is ignored for them (see SlowIndexingHelpers)
    field :index_cutoff_date, :date
    # nil inherits the profile period; zero explicitly disables age-based cleanup.
    field :retention_period_days, :integer
    field :original_url, :string
    field :title_filter_regex, :string
    field :download_subdirectory, :string
    field :output_path_template_override, :string
    field :output_path_template_shorts_override, :string

    field :min_duration_seconds, :integer
    field :max_duration_seconds, :integer

    field :series_directory, :string
    field :nfo_filepath, :string
    field :poster_filepath, :string
    field :custom_poster_filename, :string
    field :fanart_filepath, :string
    field :banner_filepath, :string

    field :marked_for_deletion_at, :utc_datetime

    belongs_to :media_profile, MediaProfile

    has_one :metadata, SourceMetadata, on_replace: :update

    has_many :tasks, Task
    has_many :media_items, MediaItem, foreign_key: :source_id, preload_order: [asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the effective age-based retention period for a source with a loaded media profile.
  A nil source value inherits; zero disables age-based deletion.
  """
  def effective_retention_period_days(%__MODULE__{
        retention_period_days: nil,
        media_profile: %MediaProfile{} = profile
      }),
      do: profile.retention_period_days

  def effective_retention_period_days(%__MODULE__{retention_period_days: days}), do: days

  @doc false
  def changeset(source, attrs, validation_stage \\ :initial) do
    # See above for rationale
    required_fields =
      if validation_stage == :initial do
        @initially_required_fields
      else
        @pre_insert_required_fields
      end

    source
    |> cast(attrs, @allowed_fields)
    |> update_change(:original_url, &normalize_youtube_host/1)
    |> normalize_show_url()
    |> dynamic_default(:custom_name, fn cs -> get_field(cs, :collection_name) end)
    |> dynamic_default(:uuid, fn _ -> Ecto.UUID.generate() end)
    |> validate_required(required_fields)
    |> validate_original_url()
    |> validate_title_regex()
    |> normalize_download_subdirectory()
    |> validate_download_subdirectory()
    |> validate_min_and_max_durations()
    |> validate_index_cutoff_date()
    |> normalize_player_client_fallbacks()
    |> validate_player_client_fallbacks()
    |> validate_player_client_cookie_compatibility()
    |> validate_number(:retention_period_days, greater_than_or_equal_to: 0)
    # Ensures it ends with `.{{ ext }}` or `.%(ext)s` or similar (with a little wiggle room)
    |> validate_format(:output_path_template_override, MediaProfile.ext_regex(), message: "must end with .{{ ext }}")
    |> validate_format(:output_path_template_shorts_override, MediaProfile.ext_regex(),
      message: "must end with .{{ ext }}"
    )
    |> cast_assoc(:metadata, with: &SourceMetadata.changeset/2, required: false)
    |> unique_constraint([:collection_id, :media_profile_id, :title_filter_regex], error_key: :original_url)
  end

  @doc """
  Returns the finite list of supported YouTube player-client choices.

  The `nil`/Default choice is rendered by the source form and is intentionally
  not part of this list because it means that yt-dlp should receive no override.
  """
  def player_client_options, do: @player_client_options

  @doc """
  Returns the finite set of player-client atoms accepted by the schema.
  """
  def player_client_values, do: @player_client_values

  @doc """
  Returns the display label for a player-client value.
  """
  def player_client_label(nil), do: "Default"

  def player_client_label(player_client) when is_atom(player_client) do
    case Enum.find(@player_client_options, fn {_label, val} -> val == player_client end) do
      {label, _val} -> label
      nil -> to_string(player_client)
    end
  end

  def player_client_label(player_client) when is_binary(player_client) do
    case Enum.find(@player_client_options, fn {_label, val} -> to_string(val) == player_client end) do
      {label, _val} -> label
      nil -> player_client
    end
  end

  @doc """
  Returns the list of player clients that do not support account cookies.
  """
  def cookie_incompatible_player_clients, do: @cookie_incompatible_player_clients

  @doc """
  Returns the effective ordered client chain as a list of atoms (or `[nil]`).
  Guarantees:
  - Deduplicated
  - At most 4 clients total
  - If primary is nil and fallbacks is empty: `[nil]`
  """
  def effective_client_chain(nil), do: [nil]
  def effective_client_chain(%Source{player_client: nil, player_client_fallbacks: []}), do: [nil]
  def effective_client_chain(%Source{player_client: nil, player_client_fallbacks: nil}), do: [nil]

  def effective_client_chain(%Source{player_client: primary, player_client_fallbacks: fallbacks}) do
    valid_atoms_map = Map.new(@player_client_values, fn a -> {to_string(a), a} end)

    converted_fallbacks =
      (fallbacks || [])
      |> Enum.map(fn
        a when is_atom(a) -> a
        s when is_binary(s) -> Map.get(valid_atoms_map, s)
      end)
      |> Enum.reject(&is_nil/1)

    chain =
      [primary | converted_fallbacks]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(4)

    case chain do
      [] -> [nil]
      items -> items
    end
  end

  @doc """
  Returns the source-type choices shown while creating a source.

  The selected value is transient form state. The persisted source type remains
  collection_type, which is populated from inspected source metadata.
  """
  def source_type_options, do: @source_type_options

  @doc false
  def index_frequency_when_fast_indexing do
    # 30 days in minutes
    60 * 24 * 30
  end

  @doc false
  def fast_index_frequency do
    # minutes
    10
  end

  @doc false
  def filepath_attributes do
    ~w(nfo_filepath fanart_filepath poster_filepath banner_filepath)a
  end

  @doc false
  def json_exluded_fields do
    ~w(__meta__ __struct__ metadata tasks media_items custom_poster_filename source_type)a
  end

  @doc false
  def to_json_map(%Source{} = source) do
    excluded_fields = json_exluded_fields()

    source
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} ->
      key in excluded_fields || match?(%Ecto.Association.NotLoaded{}, value)
    end)
    |> Enum.into(%{})
    |> then(fn fields ->
      if match?(%MediaProfile{}, source.media_profile) do
        Map.put(fields, :effective_retention_period_days, effective_retention_period_days(source))
      else
        fields
      end
    end)
  end

  def youtube_video_url?(url) when is_binary(url) do
    url = normalize_youtube_host(url)

    youtube_patterns = [
      ~r<^https?://(?:www\.)?youtube\.com/watch\?[^#]*\bv=[^&]+>,
      ~r<^https?://(?:www\.)?youtube\.com/shorts/[^/?#]+>,
      ~r<^https?://(?:www\.)?youtube\.com/embed/[^/?#]+>,
      ~r<^https?://youtu\.be/[^/?#]+>
    ]

    Enum.any?(youtube_patterns, &Regex.match?(&1, url))
  end

  def youtube_video_url?(_url), do: false

  def supported_youtube_url?(url) when is_binary(url) do
    url = normalize_youtube_host(url)

    supported_patterns = [
      ~r<^https?://(?:www\.)?youtube\.com/channel/[^/?#]+(?:/(?:featured|videos|shorts|streams|live))?$>,
      ~r<^https?://(?:www\.)?youtube\.com/@[^/?#]+(?:/(?:featured|videos|shorts|streams|live))?$>,
      ~r<^https?://(?:www\.)?youtube\.com/c/[^/?#]+(?:/(?:featured|videos|shorts|streams|live))?$>,
      ~r<^https?://(?:www\.)?youtube\.com/user/[^/?#]+(?:/(?:featured|videos|shorts|streams|live))?$>,
      ~r<^https?://(?:www\.)?youtube\.com/playlist\?list=[^&]+>
    ]

    youtube_video_url?(url) ||
      Enum.any?(supported_patterns, &Regex.match?(&1, url)) ||
      supported_youtube_custom_path?(url)
  end

  def supported_youtube_url?(_url), do: false

  defp normalize_youtube_host(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil} = uri}
      when (scheme == "https" and port == 443) or (scheme == "http" and port == 80) ->
        if is_binary(host) and String.downcase(host) in ["music.youtube.com", "m.youtube.com"] do
          URI.to_string(%{uri | host: "www.youtube.com"})
        else
          url
        end

      _ ->
        url
    end
  end

  defp normalize_youtube_host(url), do: url

  defp normalize_show_url(changeset) do
    update_change(changeset, :original_url, fn url ->
      case URI.parse(url || "") do
        %URI{scheme: scheme, host: host, path: "/show/VL" <> playlist_id, userinfo: nil}
        when scheme in ["http", "https"] and host in ["youtube.com", "www.youtube.com"] ->
          if Regex.match?(~r/\APL[A-Za-z0-9_-]+\z/, playlist_id) do
            "https://www.youtube.com/playlist?list=#{playlist_id}"
          else
            url
          end

        _ ->
          url
      end
    end)
  end

  defp validate_original_url(%{changes: %{original_url: url}} = changeset) when is_binary(url) do
    if String.contains?(url, ["youtube.com", "youtu.be"]) && !supported_youtube_url?(url) do
      add_error(changeset, :original_url, "must be a channel, playlist, or single video URL")
    else
      changeset
    end
  end

  defp validate_original_url(changeset), do: changeset

  defp normalize_download_subdirectory(changeset) do
    update_change(changeset, :download_subdirectory, fn
      nil ->
        nil

      value ->
        value
        |> String.trim()
        |> String.replace("\\", "/")
        |> String.trim("/")
        |> case do
          "" -> nil
          normalized -> normalized
        end
    end)
  end

  defp validate_download_subdirectory(changeset) do
    validate_change(changeset, :download_subdirectory, fn :download_subdirectory, value ->
      cond do
        is_nil(value) ->
          []

        String.starts_with?(value, "/") ->
          [download_subdirectory: "must be a relative path under the media root"]

        Regex.match?(~r/^[A-Za-z]:/, value) ->
          [download_subdirectory: "must be a relative path under the media root"]

        Enum.any?(String.split(value, "/", trim: true), &(&1 == "..")) ->
          [download_subdirectory: "cannot contain parent directory segments"]

        true ->
          []
      end
    end)
  end

  defp supported_youtube_custom_path?(url) do
    case URI.parse(url) do
      %URI{host: host, path: path}
      when host in ["youtube.com", "www.youtube.com"] and is_binary(path) ->
        case String.split(path, "/", trim: true) do
          [segment] ->
            valid_youtube_custom_path_segment?(segment)

          [segment, suffix] when suffix in ["featured", "videos"] ->
            valid_youtube_custom_path_segment?(segment)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp valid_youtube_custom_path_segment?(segment) do
    segment != "" &&
      segment not in ~w(channel user c watch watch_videos playlist feed results shorts embed live clip) &&
      !String.starts_with?(segment, "@")
  end

  defp validate_title_regex(%{changes: %{title_filter_regex: regex}} = changeset) when is_binary(regex) do
    case validate_regex(regex) do
      {:ok, _} -> changeset
      _ -> add_error(changeset, :title_filter_regex, "is invalid")
    end
  end

  defp validate_title_regex(changeset), do: changeset

  defp validate_regex(regex) do
    if Pinchflat.Database.postgres?() do
      Repo.query("SELECT '' ~ $1", [regex])
    else
      Repo.query("SELECT regexp_like('', ?)", [regex])
    end
  end

  # An indexing cutoff after the download cutoff would stop indexing before
  # reaching media the download cutoff still allows — that media would never be
  # indexed, so it could never be downloaded
  defp validate_index_cutoff_date(changeset) do
    index_cutoff = get_field(changeset, :index_cutoff_date)
    download_cutoff = get_field(changeset, :download_cutoff_date)

    if index_cutoff && download_cutoff && Date.compare(index_cutoff, download_cutoff) == :gt do
      add_error(changeset, :index_cutoff_date, "must be on or before the download cutoff date")
    else
      changeset
    end
  end

  defp normalize_player_client_fallbacks(changeset) do
    case get_change(changeset, :player_client_fallbacks) do
      list when is_list(list) ->
        cleaned =
          list
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        put_change(changeset, :player_client_fallbacks, cleaned)

      _ ->
        changeset
    end
  end

  defp validate_player_client_fallbacks(changeset) do
    player_client = get_field(changeset, :player_client)
    fallbacks = get_field(changeset, :player_client_fallbacks) || []

    valid_client_strings = Enum.map(@player_client_values, &to_string/1)

    invalid_entries =
      Enum.reject(fallbacks, fn
        entry when is_binary(entry) -> entry in valid_client_strings
        entry when is_atom(entry) -> entry in @player_client_values
        _ -> false
      end)

    cond do
      not is_list(fallbacks) ->
        add_error(changeset, :player_client_fallbacks, "must be a list")

      invalid_entries != [] ->
        add_error(
          changeset,
          :player_client_fallbacks,
          "contains unsupported clients: #{Enum.join(invalid_entries, ", ")}"
        )

      is_nil(player_client) and fallbacks != [] ->
        add_error(changeset, :player_client, "is required when fallback clients are configured")

      length(Enum.uniq(fallbacks)) != length(fallbacks) ->
        add_error(changeset, :player_client_fallbacks, "contains duplicate clients")

      player_client != nil and to_string(player_client) in Enum.map(fallbacks, &to_string/1) ->
        add_error(changeset, :player_client_fallbacks, "cannot include the primary client")

      if(player_client, do: 1, else: 0) + length(fallbacks) > 4 ->
        add_error(changeset, :player_client_fallbacks, "cannot exceed 4 total explicit clients")

      true ->
        changeset
    end
  end

  defp validate_player_client_cookie_compatibility(changeset) do
    player_client = get_field(changeset, :player_client)
    fallbacks = get_field(changeset, :player_client_fallbacks) || []
    cookie_behaviour = get_field(changeset, :cookie_behaviour)

    valid_atoms_map = Map.new(@player_client_values, fn a -> {to_string(a), a} end)

    all_clients =
      [player_client | fallbacks]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn
        c when is_atom(c) -> c
        c when is_binary(c) -> Map.get(valid_atoms_map, c)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce(all_clients, changeset, fn client, cs ->
      cond do
        client == :web_creator and cookie_behaviour == :disabled ->
          if client == player_client do
            add_error(cs, :player_client, "requires account cookies; select When Needed or All Operations")
          else
            add_error(
              cs,
              :player_client_fallbacks,
              "#{player_client_label(client)} requires account cookies; select When Needed or All Operations"
            )
          end

        client in @cookie_incompatible_player_clients and cookie_behaviour != :disabled ->
          if client == player_client do
            add_error(cs, :player_client, "does not support account cookies; set Cookie Behaviour to Disabled")
          else
            add_error(
              cs,
              :player_client_fallbacks,
              "#{player_client_label(client)} does not support account cookies; set Cookie Behaviour to Disabled"
            )
          end

        true ->
          cs
      end
    end)
  end

  defp validate_min_and_max_durations(changeset) do
    min_duration = get_change(changeset, :min_duration_seconds)
    max_duration = get_change(changeset, :max_duration_seconds)

    case {min_duration, max_duration} do
      {min, max} when is_nil(min) or is_nil(max) -> changeset
      {min, max} when min >= max -> add_error(changeset, :max_duration_seconds, "must be greater than minumum duration")
      _ -> changeset
    end
  end

  defimpl Jason.Encoder, for: Source do
    def encode(value, opts) do
      value
      |> Source.to_json_map()
      |> Jason.Encode.map(opts)
    end
  end
end
