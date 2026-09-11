defmodule Pinchflat.Database do
  @moduledoc """
  Describes the database adapter selected when this PinchYT build was compiled.

  SQLite remains the default build. PostgreSQL images are compiled separately
  so Ecto, Oban, migrations, and database-specific queries all agree on the
  adapter used by `Pinchflat.Repo`.
  """

  @adapter Application.compile_env(:pinchflat, :database_adapter, :sqlite)

  @doc "Returns the configured database adapter name."
  def adapter, do: @adapter

  @doc "Returns true when this build uses SQLite."
  def sqlite?, do: @adapter == :sqlite

  @doc "Returns true when this build uses PostgreSQL."
  def postgres?, do: @adapter == :postgres
end
