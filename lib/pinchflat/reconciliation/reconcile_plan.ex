defmodule Pinchflat.Reconciliation.ReconcilePlan do
  @moduledoc """
  A reconcile plan is one dry-run of the file reconciliation ("true-up") process:
  the full set of moves, backfills, and deletions that would bring already-downloaded
  files in line with the current path-affecting settings. Plans are persisted so the
  user reviews exactly what a later apply will execute.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Sources.Source
  alias Pinchflat.Reconciliation.ReconcilePlanItem

  @allowed_fields ~w(
    mode
    source_id
    status
    move_count
    backfill_count
    delete_count
    redownload_count
    skip_count
    collision_count
    error_count
    applied_at
    error_message
  )a

  @required_fields ~w(mode status)a

  schema "reconcile_plans" do
    field :mode, Ecto.Enum, values: [:local, :online, :full], default: :local
    field :status, Ecto.Enum, values: ~w(building ready applying applied failed stale)a, default: :building

    field :move_count, :integer, default: 0
    field :backfill_count, :integer, default: 0
    field :delete_count, :integer, default: 0
    field :redownload_count, :integer, default: 0
    field :skip_count, :integer, default: 0
    field :collision_count, :integer, default: 0
    field :error_count, :integer, default: 0

    field :applied_at, :utc_datetime
    field :error_message, :string

    belongs_to :source, Source
    has_many :reconcile_plan_items, ReconcilePlanItem

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(reconcile_plan, attrs) do
    reconcile_plan
    |> cast(attrs, @allowed_fields)
    |> validate_required(@required_fields)
  end
end
