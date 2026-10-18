defmodule Pinchflat.MediaServers.EmbyTest do
  use Pinchflat.DataCase, async: false
  import Mox

  alias Pinchflat.MediaServers.Emby

  setup :verify_on_exit!

  describe "Emby.refresh/2 - scan disclosure and execution" do
    test "refuses refresh when emby_confirm_full_scan is false or missing" do
      settings_unconfirmed = %{
        emby_url: "http://192.168.1.100:8096",
        emby_api_key: "emby_key_789",
        emby_confirm_full_scan: false
      }

      # Zero HTTP requests should be sent when unconfirmed
      assert {:error, :unconfirmed_full_scan, message} = Emby.refresh(settings_unconfirmed)
      assert message =~ "explicit confirmation"

      settings_missing = %{
        emby_url: "http://192.168.1.100:8096",
        emby_api_key: "emby_key_789"
      }

      assert {:error, :unconfirmed_full_scan, _} = Emby.refresh(settings_missing)
    end

    test "executes POST /Library/Refresh when full-scan is explicitly confirmed" do
      settings = %{
        emby_url: "http://192.168.1.100:8096/",
        emby_api_key: "emby_key_789",
        emby_confirm_full_scan: true
      }

      expect(HTTPClientMock, :post, fn url, headers, body ->
        assert url == "http://192.168.1.100:8096/Library/Refresh"
        assert {"X-Emby-Token", "emby_key_789"} in headers
        assert body == ""
        {:ok, ""}
      end)

      assert :ok = Emby.refresh(settings)
    end

    test "returns sanitized error when HTTP request fails" do
      settings = %{
        emby_url: "http://192.168.1.100:8096",
        emby_api_key: "emby_key_789",
        emby_confirm_full_scan: true
      }

      expect(HTTPClientMock, :post, fn _url, _headers, _body ->
        {:error, "HTTP request failed with status code 401"}
      end)

      assert {:error, "HTTP request failed with status code 401"} = Emby.refresh(settings)
    end
  end

  describe "Emby.test_connection/1" do
    test "calls GET /System/Info with X-Emby-Token header without requiring full-scan confirmation" do
      settings = %{
        emby_url: "http://192.168.1.100:8096",
        emby_api_key: "emby_key_789",
        emby_confirm_full_scan: false
      }

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://192.168.1.100:8096/System/Info"
        assert {"X-Emby-Token", "emby_key_789"} in headers
        {:ok, "{\"Version\":\"4.8.0.0\"}"}
      end)

      assert {:ok, :connected} = Emby.test_connection(settings)
    end
  end
end
