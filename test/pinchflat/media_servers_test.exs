defmodule Pinchflat.MediaServersTest do
  use Pinchflat.DataCase, async: false
  import Mox
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaServers
  alias Pinchflat.Settings

  setup :verify_on_exit!

  describe "dispatch_post_download_refresh/1" do
    test "downloads arriving during a scan retain one follow-up job" do
      {:ok, running} = MediaServers.enqueue_refresh(:jellyfin)
      running |> Ecto.Changeset.change(state: "executing") |> Repo.update!()

      assert {:ok, follow_up} = MediaServers.enqueue_refresh(:jellyfin)
      assert follow_up.id != running.id
      assert {:ok, duplicate} = MediaServers.enqueue_refresh(:jellyfin)
      assert duplicate.id == follow_up.id
      assert Repo.get!(Oban.Job, running.id).state == "executing"
      assert Repo.get!(Oban.Job, follow_up.id).state == "available"
    end

    test "rejects credentials and query parameters embedded in server URLs" do
      for url <- ["http://user:secret@owned.example", "http://owned.example?key=secret", "http://owned.example#ignored"] do
        assert {:error, changeset} =
                 Settings.update_setting(Settings.record(), %{plex_enabled: true, plex_url: url, plex_token: "owned"})

        assert changeset.errors[:plex_url]
      end
    end

    test "enqueues jobs only for enabled media servers" do
      media_item = media_item_fixture(%{source_id: source_fixture().id})

      # Initially all disabled
      assert [] = MediaServers.dispatch_post_download_refresh(media_item)

      # Enable Plex and Jellyfin
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          plex_enabled: true,
          plex_url: "http://plex.local:32400",
          plex_token: "plex_tok",
          jellyfin_enabled: true,
          jellyfin_url: "http://jelly.local:8096",
          jellyfin_api_key: "jelly_key",
          emby_enabled: false
        })

      jobs = MediaServers.dispatch_post_download_refresh(media_item)
      assert length(jobs) == 2

      server_types =
        Enum.map(jobs, fn {:ok, job} ->
          assert job.queue == "default"
          assert job.worker == "Pinchflat.MediaServers.RefreshWorker"
          assert Map.has_key?(job.args, "server_type")
          job.args["server_type"]
        end)

      assert "plex" in server_types
      assert "jellyfin" in server_types
      refute "emby" in server_types
    end

    test "coalesces refreshes for different media items into a single job per server" do
      {:ok, _} = MediaServers.enqueue_refresh(:jellyfin, %Pinchflat.Media.MediaItem{id: 501})
      {:ok, _} = MediaServers.enqueue_refresh(:jellyfin, %Pinchflat.Media.MediaItem{id: 502})
      import Ecto.Query
      assert Repo.aggregate(from(j in Oban.Job, where: j.worker == "Pinchflat.MediaServers.RefreshWorker"), :count) == 1
    end
  end

  describe "refresh/2 guards and routing" do
    test "returns {:error, :disabled} when requested server is not enabled" do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          plex_enabled: false,
          jellyfin_enabled: false,
          emby_enabled: false
        })

      assert {:error, :disabled} = MediaServers.refresh(:plex, nil)
      assert {:error, :disabled} = MediaServers.refresh(:jellyfin, nil)
      assert {:error, :disabled} = MediaServers.refresh(:emby, nil)
    end

    test "routes to client implementation when enabled" do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          plex_enabled: true,
          plex_url: "http://plex.local:32400",
          plex_token: "tok",
          plex_library_section_id: "all"
        })

      expect(HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url =~ "sections/all/refresh"
        {:ok, "ok"}
      end)

      assert :ok = MediaServers.refresh(:plex, nil)
    end
  end

  describe "test_connection/2" do
    test "dispatches test to appropriate server module" do
      expect(HTTPClientMock, :get, fn url, headers, _opts ->
        assert url == "http://test-plex:32400/library/sections"
        assert {"X-Plex-Token", "t"} in headers
        {:ok, "ok"}
      end)

      custom = %{
        plex_url: "http://test-plex:32400",
        plex_token: "t"
      }

      assert {:ok, :connected} = MediaServers.test_connection(:plex, custom)
    end
  end
end
