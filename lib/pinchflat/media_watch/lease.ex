defmodule Pinchflat.MediaWatch.Lease do
  @moduledoc """
  An opaque per-item ownership token for a watched file operation.

  The token carries the watch row's monotonic lease generation and observation
  version. A caller must re-check it immediately before mutating active files;
  an expired or superseded token is not permission to continue.
  """

  @type t :: %__MODULE__{
          watch_id: integer(),
          owner: String.t(),
          generation: integer(),
          observation_version: integer(),
          expires_at: DateTime.t(),
          operation_kind: String.t()
        }

  defstruct [:watch_id, :owner, :generation, :observation_version, :expires_at, :operation_kind]
end
