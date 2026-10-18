defmodule Pinchflat.MediaServers.JellyfinTest do
  use Pinchflat.DataCase, async: false
  import Mox

  alias Pinchflat.MediaServers.Jellyfin

  setup :verify_on_exit!

  describe "Jellyfin.refresh/2" do
    test "constructs POST /Library/Refresh with MediaBrowser authorization" do
      settings = %{
        jellyfin_url: "http://192.168.1.100:8096/",
        jellyfin_api_key: "jelly_api_token_456"
      }

      expect(HTTPClientMock, :post, fn url, headers, body ->
        assert url == "http://192.168.1.100:8096/Library/Refresh"
        assert {"Authorization", ~s(MediaBrowser Token="jelly_api_token_456")} in headers
        assert body == ""
        {:ok, ""}
      end)

      assert :ok = Jellyfin.refresh(settings)
    end

    test "returns sanitized error when HTTP request fails" do
      settings = %{
        jellyfin_url: "http://192.168.1.100:8096",
        jellyfin_api_key: "jelly_api_token"
      }

      expect(HTTPClientMock, :post, fn _url, _headers, _body ->
        {:error, "HTTP request failed with status code 401"}
      end)

      assert {:error, "HTTP request failed with status code 401"} = Jellyfin.refresh(settings)
    end

    test "returns error when URL or API key is missing" do
      assert {:error, :missing_configuration} = Jellyfin.refresh(%{jellyfin_url: "", jellyfin_api_key: "key"})

      assert {:error, :missing_configuration} =
               Jellyfin.refresh(%{jellyfin_url: "http://localhost", jellyfin_api_key: ""})
    end
  end

  describe "Jellyfin.test_connection/1" do
    test "calls GET /System/Info with MediaBrowser authorization" do
      settings = %{
        jellyfin_url: "http://192.168.1.100:8096",
        jellyfin_api_key: "jelly_api_token_456"
      }

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://192.168.1.100:8096/System/Info"
        assert {"Authorization", ~s(MediaBrowser Token="jelly_api_token_456")} in headers
        {:ok, "{\"Version\":\"10.9.0\",\"ServerName\":\"MyServer\"}"}
      end)

      assert {:ok, :connected} = Jellyfin.test_connection(settings)
    end

    test "returns sanitized error when test connection fails" do
      settings = %{
        jellyfin_url: "http://192.168.1.100:8096",
        jellyfin_api_key: "bad_key"
      }

      expect(HTTPClientMock, :get, fn _url, _headers ->
        {:error, "HTTP request failed with status code 401"}
      end)

      assert {:error, "HTTP request failed with status code 401"} = Jellyfin.test_connection(settings)
    end
  end

  test "escapes API keys as quoted authorization parameters" do
    settings = %{jellyfin_url: "http://jelly.local", jellyfin_api_key: ~S(a"b\c)}

    expect(HTTPClientMock, :get, fn _url, headers ->
      assert headers == [{"Authorization", ~S(MediaBrowser Token="a\"b\\c")}]
      {:ok, ""}
    end)

    assert {:ok, :connected} = Jellyfin.test_connection(settings)
  end
end
