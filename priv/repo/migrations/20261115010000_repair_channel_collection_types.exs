defmodule Pinchflat.Repo.Migrations.RepairChannelCollectionTypes do
  use Ecto.Migration

  import Ecto.Query

  def up do
    ids =
      repo().all(
        from(s in "sources",
          where: s.collection_type == "playlist",
          select: %{id: s.id, collection_id: s.collection_id, original_url: s.original_url}
        )
      )
      |> Enum.filter(&channel_source?/1)
      |> Enum.map(& &1.id)

    repo().update_all(from(s in "sources", where: s.id in ^ids),
      set: [collection_type: "channel"]
    )
  end

  # Corrected types remain valid on rollback; names, settings and files are untouched.
  def down, do: :ok

  defp channel_source?(%{collection_id: id, original_url: url})
       when is_binary(id) and is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || ""
    query = URI.decode_query(uri.query || "")

    Regex.match?(~r/^UC[A-Za-z0-9_-]{22}$/, id) and uri.scheme in ["http", "https"] and
      uri.host in ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"] and
      not Map.has_key?(query, "list") and
      (Regex.match?(~r{^/@[^/]+(?:/(?:videos|shorts|streams|live))?/?$}, path) or
         path in Enum.map(
           ["", "/", "/videos", "/shorts", "/streams", "/live"],
           &("/channel/#{id}" <> &1)
         ) or
         Regex.match?(~r{^/(?:c|user)/[^/]+/?$}, path))
  rescue
    ArgumentError -> false
  end

  defp channel_source?(_source), do: false
end
