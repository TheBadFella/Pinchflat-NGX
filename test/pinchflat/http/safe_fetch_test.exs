defmodule Pinchflat.HTTP.SafeFetchTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pinchflat.HTTP.SafeFetch

  setup :verify_on_exit!

  setup do
    original_allowlist = Application.get_env(:pinchflat, :yt_dlp_plugin_url_allowlist)
    original_allow_private = Application.get_env(:pinchflat, :yt_dlp_plugin_url_allow_private)

    Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["example.com", "cdn.example.com"])
    Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, false)

    on_exit(fn ->
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, original_allowlist)
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, original_allow_private)
    end)

    :ok
  end

  describe "parse_host_list/1" do
    test "normalizes comma-separated hosts" do
      assert SafeFetch.parse_host_list(" Example.com, cdn.example.com ,, ") == ["example.com", "cdn.example.com"]
    end

    test "accepts lists and nil" do
      assert SafeFetch.parse_host_list(["Example.com", "", "cdn.example.com"]) == [
               "example.com",
               "cdn.example.com"
             ]

      assert SafeFetch.parse_host_list(nil) == []
    end
  end

  describe "allowed_hosts/0" do
    test "includes the built-in defaults and configured hosts" do
      hosts = SafeFetch.allowed_hosts()

      assert "github.com" in hosts
      assert "example.com" in hosts
    end
  end

  describe "fetch/2" do
    test "fetches a body from an allowed host and pins the resolved address" do
      expect(HTTPClientMock, :get_with_response, fn url, headers, opts ->
        assert url == "https://example.com/plugin.zip"
        assert headers == [{"user-agent", "pinchflat-ngx"}]
        assert opts[:connect_address] == {93, 184, 216, 34}
        assert opts[:receive_timeout] == 30_000
        assert opts[:request_timeout] == 60_000

        {:ok, %{status: 200, headers: [{"content-length", "4"}], body: "data"}}
      end)

      assert {:ok, "data"} = SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver())
    end

    test "uses the configured DNS resolver when none is passed" do
      original_resolver = Application.get_env(:pinchflat, :yt_dlp_plugin_url_dns_resolver)

      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["mirror.internal"])

      Application.put_env(:pinchflat, :yt_dlp_plugin_url_dns_resolver, fn _host ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      on_exit(fn ->
        Application.put_env(:pinchflat, :yt_dlp_plugin_url_dns_resolver, original_resolver)
      end)

      expect(HTTPClientMock, :get_with_response, 1, fn _, _, opts ->
        assert opts[:connect_address] == {93, 184, 216, 34}
        {:ok, %{status: 200, headers: [], body: "data"}}
      end)

      assert {:ok, "data"} = SafeFetch.fetch("https://mirror.internal/plugin.zip")
    end

    test "rejects a host outside the allowlist without resolving or calling HTTP" do
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)
      resolver = fn _host -> flunk("unexpected DNS resolution") end

      assert {:error, :host_not_allowed} =
               SafeFetch.fetch("https://evil.example/plugin.zip", dns_resolver: resolver)
    end

    test "rejects a public host resolving to a private IPv4 address" do
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      assert {:error, :unsafe_url} =
               SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver({127, 0, 0, 1}))
    end

    test "rejects a public host resolving to IPv6 loopback" do
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      assert {:error, :unsafe_url} =
               SafeFetch.fetch("https://example.com/plugin.zip",
                 dns_resolver: public_resolver({0, 0, 0, 0, 0, 0, 0, 1})
               )
    end

    test "rejects special-purpose IPv6 ranges" do
      addresses = [
        {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
        {0x0064, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
        {0x2002, 0x7F00, 1, 0, 0, 0, 0, 0},
        {0x2001, 0, 0, 0, 0, 0, 0, 1}
      ]

      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      for address <- addresses do
        assert {:error, :unsafe_url} =
                 SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver(address))
      end
    end

    test "rejects credentials in the URL" do
      assert {:error, :invalid_url} =
               SafeFetch.fetch("https://user:pass@example.com/plugin.zip", dns_resolver: public_resolver())
    end

    test "rejects unsupported schemes" do
      assert {:error, :invalid_url} = SafeFetch.fetch("file:///etc/passwd", dns_resolver: public_resolver())
    end

    test "rejects a URL without a host" do
      assert {:error, :invalid_url} = SafeFetch.fetch("not a url", dns_resolver: public_resolver())
    end

    test "rejects an unresolvable host" do
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      assert {:error, :unresolvable_host} =
               SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: fn _ -> {:error, :unresolvable_host} end)
    end

    test "follows a relative redirect and re-validates the target" do
      stub(HTTPClientMock, :get_with_response, fn
        "https://example.com/start.zip", _headers, opts ->
          assert opts[:connect_address] == {93, 184, 216, 34}
          {:ok, %{status: 302, headers: [{"location", "/final.zip"}], body: ""}}

        "https://example.com/final.zip", _headers, opts ->
          assert opts[:connect_address] == {93, 184, 216, 34}
          {:ok, %{status: 200, headers: [], body: "final"}}
      end)

      assert {:ok, "final"} = SafeFetch.fetch("https://example.com/start.zip", dns_resolver: public_resolver())
    end

    test "follows an absolute redirect to another allowed host" do
      resolver = fn
        "example.com" -> {:ok, [{93, 184, 216, 34}]}
        "cdn.example.com" -> {:ok, [{151, 101, 1, 1}]}
      end

      stub(HTTPClientMock, :get_with_response, fn
        "https://example.com/start.zip", _headers, opts ->
          assert opts[:connect_address] == {93, 184, 216, 34}
          {:ok, %{status: 301, headers: [{"Location", "https://cdn.example.com/final.zip"}], body: ""}}

        "https://cdn.example.com/final.zip", _headers, opts ->
          assert opts[:connect_address] == {151, 101, 1, 1}
          {:ok, %{status: 200, headers: [], body: "final"}}
      end)

      assert {:ok, "final"} = SafeFetch.fetch("https://example.com/start.zip", dns_resolver: resolver)
    end

    test "rejects a redirect to a host outside the allowlist" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 302, headers: [{"location", "https://evil.example/final.zip"}], body: ""}}
      end)

      assert {:error, :host_not_allowed} =
               SafeFetch.fetch("https://example.com/start.zip", dns_resolver: public_resolver())
    end

    test "rejects a redirect that resolves to a private address" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 302, headers: [{"location", "/private.zip"}], body: ""}}
      end)

      Process.put(:safe_fetch_resolver_calls, 0)

      resolver = fn _host ->
        calls = Process.get(:safe_fetch_resolver_calls, 0)
        Process.put(:safe_fetch_resolver_calls, calls + 1)

        if calls == 0, do: {:ok, [{93, 184, 216, 34}]}, else: {:ok, [{127, 0, 0, 1}]}
      end

      assert {:error, :unsafe_url} =
               SafeFetch.fetch("https://example.com/start.zip", dns_resolver: resolver)
    end

    test "stops after the maximum number of redirects" do
      stub(HTTPClientMock, :get_with_response, fn _url, _headers, _opts ->
        {:ok, %{status: 302, headers: [{"location", "/loop.zip"}], body: ""}}
      end)

      assert {:error, :too_many_redirects} =
               SafeFetch.fetch("https://example.com/start.zip",
                 dns_resolver: public_resolver(),
                 max_redirects: 2
               )
    end

    test "rejects a redirect without a location header" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 302, headers: [], body: ""}}
      end)

      assert {:error, :invalid_redirect} =
               SafeFetch.fetch("https://example.com/start.zip", dns_resolver: public_resolver())
    end

    test "rejects a content-length over the limit" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 200, headers: [{"content-length", "5"}], body: "data"}}
      end)

      assert {:error, :too_large} =
               SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver(), max_bytes: 4)
    end

    test "asks the HTTP client to stop reading at the size limit" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, opts ->
        assert opts[:max_bytes] == 4
        {:error, :too_large}
      end)

      assert {:error, :too_large} =
               SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver(), max_bytes: 4)
    end

    test "limits each redirect hop to the same size" do
      expect(HTTPClientMock, :get_with_response, 2, fn
        "https://example.com/start.zip", _, opts ->
          assert opts[:max_bytes] == SafeFetch.max_bytes()
          {:ok, %{status: 302, headers: [{"location", "https://example.com/final.zip"}], body: ""}}

        "https://example.com/final.zip", _, opts ->
          assert opts[:max_bytes] == SafeFetch.max_bytes()
          {:ok, %{status: 200, headers: [], body: "data"}}
      end)

      assert {:ok, "data"} = SafeFetch.fetch("https://example.com/start.zip", dns_resolver: public_resolver())
    end

    test "rejects a body over the limit" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 200, headers: [], body: "12345"}}
      end)

      assert {:error, :too_large} =
               SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver(), max_bytes: 4)
    end

    test "returns the final HTTP status" do
      expect(HTTPClientMock, :get_with_response, 1, fn _, _, _ ->
        {:ok, %{status: 404, headers: [], body: "missing"}}
      end)

      assert {:error, {:http_status, 404}} =
               SafeFetch.fetch("https://example.com/plugin.zip", dns_resolver: public_resolver())
    end

    test "allows private addresses for explicitly configured hosts when opted in" do
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["mirror.internal"])
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, true)

      expect(HTTPClientMock, :get_with_response, 1, fn _url, _headers, opts ->
        assert opts[:connect_address] == {192, 168, 1, 10}
        {:ok, %{status: 200, headers: [], body: "plugin"}}
      end)

      assert {:ok, "plugin"} =
               SafeFetch.fetch("https://mirror.internal/plugin.zip",
                 dns_resolver: public_resolver({192, 168, 1, 10})
               )
    end

    test "still rejects private addresses for built-in default hosts when opted in" do
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, true)
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      assert {:error, :unsafe_url} =
               SafeFetch.fetch("https://github.com/plugin.zip",
                 dns_resolver: public_resolver({192, 168, 1, 10})
               )
    end

    test "treats false-like opt-in values as disabled" do
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["mirror.internal"])
      expect(HTTPClientMock, :get_with_response, 0, fn _, _, _ -> flunk("unexpected HTTP request") end)

      for value <- ["false", "0", "no", "off", ""] do
        Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, value)

        assert {:error, :unsafe_url} =
                 SafeFetch.fetch("https://mirror.internal/plugin.zip",
                   dns_resolver: public_resolver({192, 168, 1, 10})
                 )
      end
    end

    test "treats true-like opt-in strings as enabled" do
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allowlist, ["mirror.internal"])
      Application.put_env(:pinchflat, :yt_dlp_plugin_url_allow_private, "true")

      expect(HTTPClientMock, :get_with_response, 1, fn _url, _headers, opts ->
        assert opts[:connect_address] == {192, 168, 1, 10}
        {:ok, %{status: 200, headers: [], body: "plugin"}}
      end)

      assert {:ok, "plugin"} =
               SafeFetch.fetch("https://mirror.internal/plugin.zip",
                 dns_resolver: public_resolver({192, 168, 1, 10})
               )
    end
  end

  defp public_resolver(ip \\ {93, 184, 216, 34}) do
    fn _host -> {:ok, [ip]} end
  end
end
