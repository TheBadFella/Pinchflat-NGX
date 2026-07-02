defmodule Pinchflat.YtDlp.ReleaseLookupTest do
  use Pinchflat.DataCase

  alias Pinchflat.YtDlp.ReleaseLookup

  describe "latest_stable_version/1" do
    test "returns the tag name from the GitHub response" do
      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "releases/latest"
        {:ok, Jason.encode!(%{"tag_name" => "2025.07.01"})}
      end)

      assert {:ok, "2025.07.01"} = ReleaseLookup.latest_stable_version()
    end

    test "returns an error when the response is missing the tag" do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:ok, Jason.encode!(%{})} end)

      assert {:error, :unexpected_response} = ReleaseLookup.latest_stable_version()
    end

    test "passes through HTTP errors" do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, "boom"} end)

      assert {:error, "boom"} = ReleaseLookup.latest_stable_version()
    end
  end

  describe "version_available?/1" do
    test "returns true when the release tag resolves" do
      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "releases/tags/2025.07.01"
        {:ok, "{}"}
      end)

      assert ReleaseLookup.version_available?("2025.07.01")
    end

    test "returns false when the release tag is missing" do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, "not found"} end)

      refute ReleaseLookup.version_available?("9999.99.99")
    end

    test "returns false for blank input without making a request" do
      refute ReleaseLookup.version_available?("")
      refute ReleaseLookup.version_available?(nil)
    end
  end
end
