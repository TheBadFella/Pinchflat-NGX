defmodule Pinchflat.MediaServers.PlexTest do
  use Pinchflat.DataCase, async: false
  import Mox

  alias Pinchflat.MediaServers.Plex

  setup :verify_on_exit!

  describe "Plex.refresh/2" do
    test "rejects section IDs that can change the request path" do
      assert {:error, :invalid_library_section} =
               Plex.refresh(%{
                 plex_url: "http://owned.example",
                 plex_token: "owned",
                 plex_library_section_id: "1/../2?x=1"
               })
    end

    test "constructs targeted section refresh URL with X-Plex-Token header" do
      settings = %{
        plex_url: "http://192.168.1.100:32400/",
        plex_token: "secret_plex_token_123",
        plex_library_section_id: "3"
      }

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://192.168.1.100:32400/library/sections/3/refresh"
        assert {"X-Plex-Token", "secret_plex_token_123"} in headers
        {:ok, "success"}
      end)

      assert :ok = Plex.refresh(settings)
    end

    test "constructs all-sections refresh URL when section is 'all' or empty" do
      settings = %{
        plex_url: "http://192.168.1.100:32400",
        plex_token: "secret_plex_token_123",
        plex_library_section_id: "all"
      }

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://192.168.1.100:32400/library/sections/all/refresh"
        assert {"X-Plex-Token", "secret_plex_token_123"} in headers
        {:ok, "success"}
      end)

      assert :ok = Plex.refresh(settings)
    end

    test "returns sanitized error when HTTP request fails" do
      settings = %{
        plex_url: "http://192.168.1.100:32400",
        plex_token: "secret_token",
        plex_library_section_id: "all"
      }

      expect(HTTPClientMock, :get, fn _url, _headers ->
        {:error, "HTTP request failed with status code 401"}
      end)

      assert {:error, "HTTP request failed with status code 401"} = Plex.refresh(settings)
    end

    test "returns error when URL or token is missing" do
      assert {:error, :missing_configuration} = Plex.refresh(%{plex_url: "", plex_token: "tok"})

      assert {:error, :missing_configuration} =
               Plex.refresh(%{plex_url: "http://localhost", plex_token: ""})
    end
  end

  describe "Plex.test_connection/1" do
    test "calls /library/sections endpoint with X-Plex-Token header" do
      settings = %{
        plex_url: "http://192.168.1.100:32400",
        plex_token: "secret_plex_token_123"
      }

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url == "http://192.168.1.100:32400/library/sections"
        assert {"X-Plex-Token", "secret_plex_token_123"} in headers
        {:ok, "<MediaContainer size=\"0\"></MediaContainer>"}
      end)

      assert {:ok, :connected} = Plex.test_connection(settings)
    end

    test "returns sanitized error if connection fails" do
      settings = %{
        plex_url: "http://192.168.1.100:32400",
        plex_token: "bad_token"
      }

      expect(HTTPClientMock, :get, fn _url, _headers ->
        {:error, "HTTP request failed with status code 401"}
      end)

      assert {:error, "HTTP request failed with status code 401"} = Plex.test_connection(settings)
    end
  end
end
