defmodule Pinchflat.HTTP.HTTPClientTest do
  use ExUnit.Case, async: true

  alias Pinchflat.HTTP.HTTPClient

  @chunk_bytes 256 * 1024
  @chunk_count 200
  @limit 1_048_576

  defmodule TestServer do
    @moduledoc false
    import Plug.Conn

    @chunk_bytes 256 * 1024
    @chunk_count 200

    def init(counter), do: counter

    def call(%{request_path: "/small"} = conn, _counter), do: send_resp(conn, 200, "hello")
    def call(%{request_path: "/missing"} = conn, _counter), do: send_resp(conn, 404, String.duplicate("x", 2_000_000))

    def call(%{request_path: "/redirect"} = conn, _counter) do
      conn
      |> put_resp_header("location", "/small")
      |> send_resp(302, String.duplicate("x", 2_000_000))
    end

    # Declares its size up front, so the client can refuse it before reading any of the body.
    def call(%{request_path: "/declared"} = conn, _counter), do: send_resp(conn, 200, String.duplicate("x", 2_000_000))

    # Streams a chunked body with no content-length until the client hangs up, counting what it sent.
    def call(%{request_path: "/chunked"} = conn, counter) do
      conn = send_chunked(conn, 200)

      Enum.reduce_while(1..@chunk_count, conn, fn _index, conn ->
        case chunk(conn, :binary.copy("x", @chunk_bytes)) do
          {:ok, conn} ->
            :counters.add(counter, 1, @chunk_bytes)
            {:cont, conn}

          {:error, _reason} ->
            {:halt, conn}
        end
      end)
    end
  end

  setup do
    counter = :counters.new(1, [])

    {:ok, server} =
      Bandit.start_link(
        plug: {TestServer, counter},
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, counter: counter, base_url: "http://127.0.0.1:#{port}"}
  end

  describe "get_with_response/3 with max_bytes" do
    test "returns the whole body when it is within the limit", %{base_url: base_url} do
      assert {:ok, %{status: 200, body: "hello"}} =
               HTTPClient.get_with_response(base_url <> "/small", [], max_bytes: @limit)
    end

    test "stops reading a chunked body without a content-length once it passes the limit", %{
      base_url: base_url,
      counter: counter
    } do
      assert {:error, :too_large} = HTTPClient.get_with_response(base_url <> "/chunked", [], max_bytes: @limit)

      # Give the server a moment to notice the closed connection and stop sending.
      Process.sleep(200)
      sent = :counters.get(counter, 1)

      assert sent < @chunk_bytes * @chunk_count / 2
    end

    test "applies the limit on the address-pinned path", %{base_url: base_url} do
      assert {:error, :too_large} =
               HTTPClient.get_with_response(base_url <> "/chunked", [],
                 max_bytes: @limit,
                 connect_address: {127, 0, 0, 1}
               )

      assert {:ok, %{status: 200, body: "hello"}} =
               HTTPClient.get_with_response(base_url <> "/small", [],
                 max_bytes: @limit,
                 connect_address: {127, 0, 0, 1}
               )
    end

    test "refuses a response whose content-length is over the limit", %{base_url: base_url} do
      assert {:error, :too_large} = HTTPClient.get_with_response(base_url <> "/declared", [], max_bytes: @limit)
    end

    test "returns redirects with headers and without reading their body", %{base_url: base_url} do
      assert {:ok, %{status: 302, headers: headers, body: ""}} =
               HTTPClient.get_with_response(base_url <> "/redirect", [], max_bytes: @limit)

      assert {"location", "/small"} in headers
    end

    test "returns error statuses without reading their body", %{base_url: base_url} do
      assert {:ok, %{status: 404, body: ""}} =
               HTTPClient.get_with_response(base_url <> "/missing", [], max_bytes: @limit)
    end

    test "keeps buffering the full response when no limit is given", %{base_url: base_url} do
      assert {:ok, %{status: 200, body: body}} = HTTPClient.get_with_response(base_url <> "/declared")
      assert byte_size(body) == 2_000_000
    end
  end
end
