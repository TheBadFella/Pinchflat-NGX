defmodule Pinchflat.Repo.Migrations.WidenChannelDiscoveryTextColumns do
  use Ecto.Migration

  @varchar_limit 255

  def up do
    if Pinchflat.Database.postgres?() do
      alter table(:channel_discovery_suggestions) do
        modify :canonical_url, :text
        modify :artwork_url, :text
        modify :evidence, :text
        modify :generators, :text
      end
    end
  end

  def down do
    if Pinchflat.Database.postgres?() do
      ensure_varchar_values_fit!()

      alter table(:channel_discovery_suggestions) do
        modify :canonical_url, :string
        modify :artwork_url, :string
        modify :evidence, :string
        modify :generators, :string
      end
    end
  end

  defp ensure_varchar_values_fit! do
    query = """
    SELECT COUNT(*)
    FROM channel_discovery_suggestions
    WHERE COALESCE(char_length(canonical_url), 0) > #{@varchar_limit}
       OR COALESCE(char_length(artwork_url), 0) > #{@varchar_limit}
       OR COALESCE(char_length(evidence), 0) > #{@varchar_limit}
       OR COALESCE(char_length(generators), 0) > #{@varchar_limit}
    """

    %{rows: [[count]]} = repo().query!(query)

    if count > 0 do
      raise "cannot narrow channel discovery suggestion text columns: #{count} row(s) exceed the original varchar(#{@varchar_limit}) limit"
    end
  end
end
