defmodule Pinchflat.Profiles.MediaProfile do
  @moduledoc """
  A media profile is a set of configuration options that can be applied to many media sources
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias Pinchflat.Sources.Source

  @allowed_fields ~w(
    name
    output_path_template
    download_subs
    download_auto_subs
    embed_subs
    sub_langs
    download_thumbnail
    embed_thumbnail
    download_source_images
    download_metadata
    embed_metadata
    download_nfo
    sponsorblock_mark_categories
    sponsorblock_remove_categories
    shorts_behaviour
    livestream_behaviour
    audio_track
    preferred_resolution
    ignore_youtube_super_resolution
    media_container
    redownload_delay_days
    marked_for_deletion_at
  )a

  @required_fields ~w(name output_path_template)a

  @sponsorblock_categories ~w(sponsor intro outro selfpromo preview filler interaction music_offtopic hook)

  schema "media_profiles" do
    field :name, :string
    field :redownload_delay_days, :integer

    field :output_path_template, :string,
      default: "/{{ source_custom_name }}/{{ upload_yyyy_mm_dd }} {{ title }}/{{ title }} [{{ id }}].{{ ext }}"

    field :download_subs, :boolean, default: false
    field :download_auto_subs, :boolean, default: false
    field :embed_subs, :boolean, default: false
    field :sub_langs, :string, default: "en"

    field :download_thumbnail, :boolean, default: false
    field :embed_thumbnail, :boolean, default: false
    field :download_source_images, :boolean, default: false

    field :download_metadata, :boolean, default: false
    field :embed_metadata, :boolean, default: false

    field :download_nfo, :boolean, default: false
    field :sponsorblock_mark_categories, {:array, :string}, default: []
    field :sponsorblock_remove_categories, {:array, :string}, default: []
    # NOTE: these do NOT speed up indexing - the indexer still has to go
    # through the entire collection to determine if a media is a short or
    # a livestream.
    # NOTE: these can BOTH be set to :only which will download shorts and
    # livestreams _only_ and ignore regular media. The redundant case
    # is when one is set to :only and the other is set to :exclude.
    # See `build_format_clauses` in the Media context for more.
    field :shorts_behaviour, Ecto.Enum, values: ~w(include exclude only)a, default: :include
    field :livestream_behaviour, Ecto.Enum, values: ~w(include exclude only)a, default: :include
    field :audio_track, :string
    field :preferred_resolution, Ecto.Enum, values: ~w(4320p 2160p 1440p 1080p 720p 480p 360p audio)a, default: :"1080p"
    field :ignore_youtube_super_resolution, :boolean, default: false
    field :media_container, :string, default: nil

    field :marked_for_deletion_at, :utc_datetime

    has_many :sources, Source

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(media_profile, attrs) do
    media_profile
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
    # Ensures it ends with `.{{ ext }}` or `.%(ext)s` or similar (with a little wiggle room)
    |> validate_format(:output_path_template, ext_regex(), message: "must end with .{{ ext }}")
    |> validate_number(:redownload_delay_days, greater_than_or_equal_to: 0)
    |> validate_subset(:sponsorblock_mark_categories, @sponsorblock_categories)
    |> validate_subset(:sponsorblock_remove_categories, @sponsorblock_categories)
    |> validate_sponsorblock_categories_do_not_overlap()
    |> unique_constraint(:name)
  end

  @doc """
  Returns true if the media profile is configured for audio-only / podcast downloads.
  """
  def podcast?(%MediaProfile{preferred_resolution: :audio}), do: true
  def podcast?(%MediaProfile{}), do: false
  def podcast?(_), do: false

  @doc """
  Returns the list of SponsorBlock category identifiers a profile can act on.

  Returns [binary()]
  """
  def sponsorblock_categories, do: @sponsorblock_categories

  defp validate_sponsorblock_categories_do_not_overlap(changeset) do
    mark = get_field(changeset, :sponsorblock_mark_categories) || []
    remove = get_field(changeset, :sponsorblock_remove_categories) || []

    case Enum.filter(mark, &(&1 in remove)) do
      [] ->
        changeset

      overlap ->
        add_error(
          changeset,
          :sponsorblock_mark_categories,
          "can't mark and remove the same category: #{Enum.join(overlap, ", ")}"
        )
    end
  end

  @doc false
  def ext_regex do
    ~r/\.({{ ?ext ?}}|%\( ?ext ?\)[sS])$/
  end

  @doc false
  def json_exluded_fields do
    ~w(__meta__ __struct__ sources)a
  end

  defimpl Jason.Encoder, for: MediaProfile do
    def encode(value, opts) do
      value
      |> Map.drop(MediaProfile.json_exluded_fields())
      |> Jason.Encode.map(opts)
    end
  end
end
