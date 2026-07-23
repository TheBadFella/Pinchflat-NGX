defmodule Pinchflat.Reconciliation.ReconcilePlanItem do
  @moduledoc """
  One planned action within a reconcile plan: move/backfill/delete a single file
  (or record why it was skipped). `media_item_id` is null for source-level artifact
  rows (series NFO/images); `attribute` names which file the row is about.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source
  alias Pinchflat.Reconciliation.ReconcilePlan

  @allowed_fields ~w(
    reconcile_plan_id
    media_item_id
    source_id
    action
    attribute
    from_path
    to_path
    status
    detail
  )a

  @required_fields ~w(reconcile_plan_id action attribute)a

  schema "reconcile_plan_items" do
    field :action, Ecto.Enum, values: ~w(move backfill delete redownload skip collision)a
    # e.g. "media", "thumbnail", "nfo", "metadata", "subtitle:en",
    # "source_nfo", "source_poster", "source_fanart", "source_banner"
    field :attribute, :string
    field :from_path, :string
    field :to_path, :string
    field :status, Ecto.Enum, values: ~w(planned done skipped failed)a, default: :planned
    field :detail, :string

    belongs_to :reconcile_plan, ReconcilePlan
    belongs_to :media_item, MediaItem
    belongs_to :source, Source

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reconcile_plan_item, attrs) do
    reconcile_plan_item
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
  end
end
