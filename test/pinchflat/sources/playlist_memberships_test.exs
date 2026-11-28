defmodule Pinchflat.Sources.PlaylistMembershipsTest do
  use Pinchflat.DataCase

  import Mox
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources.PlaylistMembership
  alias Pinchflat.Sources.PlaylistMemberships

  setup :verify_on_exit!

  @channel_id "UC" <> String.duplicate("a", 22)

  setup do
    {:ok, source: source_fixture(%{collection_type: :channel, collection_id: @channel_id, playlist_subfolders: true})}
  end

  describe "refresh/1" do
    test "files each video under the first channel playlist containing it", %{source: source} do
      stub_listing(%{
        "PLfirst" => ["vid1", "vid2"],
        "PLsecond" => ["vid2", "vid3"]
      })

      assert {:ok, 4} = PlaylistMemberships.refresh(source)

      # vid2 is stored under both playlists, in the channel's order.
      assert [{"PLfirst", 0}, {"PLsecond", 1}] =
               Repo.all(
                 from m in PlaylistMembership,
                   where: m.media_id == "vid2",
                   order_by: m.position,
                   select: {m.playlist_id, m.position}
               )

      assert PlaylistMemberships.playlist_title_for(source.id, "vid1") == "First"
      assert PlaylistMemberships.playlist_title_for(source.id, "vid2") == "First"
      assert PlaylistMemberships.playlist_title_for(source.id, "vid3") == "Second"
      assert PlaylistMemberships.playlist_title_for(source.id, "other") == nil
    end

    test "replaces earlier memberships", %{source: source} do
      stub_listing(%{"PLfirst" => ["vid1"], "PLsecond" => []})
      assert {:ok, 1} = PlaylistMemberships.refresh(source)

      stub_listing(%{"PLfirst" => [], "PLsecond" => ["vid9"]})
      assert {:ok, 1} = PlaylistMemberships.refresh(source)

      assert PlaylistMemberships.playlist_title_for(source.id, "vid1") == nil
      assert PlaylistMemberships.playlist_title_for(source.id, "vid9") == "Second"
    end

    test "keeps stored memberships when a playlist cannot be read", %{source: source} do
      stub_listing(%{"PLfirst" => ["vid1"], "PLsecond" => []})
      assert {:ok, 1} = PlaylistMemberships.refresh(source)

      stub(YtDlpRunnerMock, :run, fn
        "https://www.youtube.com/channel/" <> _, :get_playlist_memberships, _opts, _template, _addl ->
          {:ok, playlists_output()}

        _url, :get_playlist_memberships, _opts, _template, _addl ->
          {:error, "HTTP Error 429", 1}
      end)

      assert {:error, "HTTP Error 429", 1} = PlaylistMemberships.refresh(source)
      assert Repo.aggregate(PlaylistMembership, :count, :id) == 1
      assert PlaylistMemberships.playlist_title_for(source.id, "vid1") == "First"
    end

    test "does nothing for non-channel sources" do
      source = source_fixture(%{collection_type: :playlist})

      assert {:error, :not_a_channel} = PlaylistMemberships.refresh(source)
    end
  end

  defp stub_listing(videos_by_playlist) do
    stub(YtDlpRunnerMock, :run, fn
      "https://www.youtube.com/channel/" <> rest, :get_playlist_memberships, _opts, "%(.{id,title})j", _addl ->
        assert rest == "#{@channel_id}/playlists"
        {:ok, playlists_output()}

      "https://www.youtube.com/playlist?list=" <> playlist_id, :get_playlist_memberships, _opts, "%(.{id})j", _addl ->
        videos = Map.fetch!(videos_by_playlist, playlist_id)
        {:ok, Enum.map_join(videos, "\n", &Phoenix.json_library().encode!(%{"id" => &1}))}
    end)
  end

  defp playlists_output do
    [%{"id" => "PLfirst", "title" => "First"}, %{"id" => "PLsecond", "title" => "Second"}]
    |> Enum.map_join("\n", &Phoenix.json_library().encode!/1)
  end
end
