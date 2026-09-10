defmodule Pinchflat.YtDlp.PoTokenProviderTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.YtDlp.PoTokenProvider

  setup :verify_on_exit!

  setup do
    original_url = Application.get_env(:pinchflat, :po_token_provider_url)
    Application.put_env(:pinchflat, :po_token_provider_url, nil)

    on_exit(fn -> Application.put_env(:pinchflat, :po_token_provider_url, original_url) end)

    :ok
  end

  describe "options/0" do
    test "keeps provider options absent when disabled" do
      assert PoTokenProvider.options() == []
      assert PoTokenProvider.plugin_options() == []
    end

    test "builds the typed bgutil extractor argument when enabled" do
      put_provider_url("http://pot-provider:4416")

      assert PoTokenProvider.options() == [
               {:extractor_args, "youtubepot-bgutilhttp:base_url=http://pot-provider:4416"}
             ]
    end

    test "rejects credentials and query parameters" do
      put_provider_url("http://user:secret@pot-provider:4416?token=should-not-be-used")

      assert PoTokenProvider.options() == []
      assert %{state: :invalid_configuration, label: "Invalid configuration"} = PoTokenProvider.status()
    end
  end

  describe "status/0" do
    test "reports disabled without making a request" do
      assert %{state: :disabled, label: "Disabled", detail: detail} = PoTokenProvider.status()
      assert detail =~ "POT_PROVIDER_URL"
    end

    test "reports a valid provider response as healthy" do
      put_provider_url("http://pot-provider:4416")

      expect(HTTPClientMock, :get, fn url, [], opts ->
        assert url == "http://pot-provider:4416/ping"
        assert opts[:pool_timeout] == 3_000
        assert opts[:receive_timeout] == 3_000
        assert opts[:request_timeout] == 3_000
        {:ok, ~s({"server_uptime":12.5,"version":"2.0.0"})}
      end)

      assert %{state: :healthy, label: "Healthy"} = PoTokenProvider.status()
    end

    test "reports connection and timeout errors as unreachable" do
      put_provider_url("http://pot-provider:4416")
      expect(HTTPClientMock, :get, fn _url, _headers, _opts -> {:error, "request timed out"} end)

      assert %{state: :unreachable, label: "Unreachable"} = PoTokenProvider.status()
    end

    test "reports malformed responses without exposing the response body" do
      put_provider_url("http://pot-provider:4416")
      secret_token = "secret-token-that-must-not-reach-the-page"

      expect(HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, ~s({"poToken":"#{secret_token}"})}
      end)

      status = PoTokenProvider.status()

      assert status.state == :invalid_response
      refute inspect(status) =~ secret_token
    end
  end

  defp put_provider_url(url), do: Application.put_env(:pinchflat, :po_token_provider_url, url)
end
