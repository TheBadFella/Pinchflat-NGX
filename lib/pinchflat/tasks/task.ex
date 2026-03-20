defmodule Pinchflat.Tasks.Task do
  @moduledoc """
  The Task schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Sources.Source

  schema "tasks" do
    belongs_to :job, Oban.Job
    belongs_to :source, Source
    belongs_to :media_item, MediaItem
    field :progress_percent, :float
    field :progress_status, :string
    field :progress_downloaded_bytes, :integer
    field :progress_total_bytes, :integer
    field :progress_eta_seconds, :integer
    field :progress_updated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :job_id,
      :source_id,
      :media_item_id,
      :progress_percent,
      :progress_status,
      :progress_downloaded_bytes,
      :progress_total_bytes,
      :progress_eta_seconds,
      :progress_updated_at
    ])
    |> validate_required([:job_id])
  end
end
