defmodule Pinchflat.MediaServers.RefreshWorkerTest do
  use Pinchflat.DataCase, async: false
  import Mox
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.MediaServers.RefreshWorker
  alias Pinchflat.Settings

  setup :verify_on_exit!

  describe "perform/1" do
    test "executes refresh successfully for enabled server" do
      media_item = media_item_fixture(%{source_id: source_fixture().id})

      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          plex_enabled: true,
          plex_url: "http://plex:32400",
          plex_token: "secret_tok",
          plex_library_section_id: "all"
        })

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://plex:32400/library/sections/all/refresh"
        assert {"X-Plex-Token", "secret_tok"} in headers
        {:ok, "done"}
      end)

      job = %Oban.Job{
        args: %{"server_type" => "plex", "media_item_id" => media_item.id}
      }

      assert :ok = RefreshWorker.perform(job)
    end

    test "gracefully skips when server is disabled" do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{plex_enabled: false})

      job = %Oban.Job{
        args: %{"server_type" => "plex"}
      }

      assert :ok = RefreshWorker.perform(job)
    end

    test "gracefully skips without failing job when Emby full-scan is unconfirmed" do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          emby_enabled: true,
          emby_url: "http://emby:8096",
          emby_api_key: "key",
          emby_confirm_full_scan: false
        })

      job = %Oban.Job{
        args: %{"server_type" => "emby"}
      }

      assert :ok = RefreshWorker.perform(job)
    end

    test "returns error tuple on HTTP failure for Oban retry" do
      {:ok, _} =
        Settings.record()
        |> Settings.update_setting(%{
          jellyfin_enabled: true,
          jellyfin_url: "http://jellyfin:8096",
          jellyfin_api_key: "key"
        })

      expect(HTTPClientMock, :post, fn _url, _headers, _body ->
        {:error, "HTTP request failed with status code 500"}
      end)

      job = %Oban.Job{
        args: %{"server_type" => "jellyfin"}
      }

      assert {:error, "HTTP request failed with status code 500"} = RefreshWorker.perform(job)
    end
  end
end
