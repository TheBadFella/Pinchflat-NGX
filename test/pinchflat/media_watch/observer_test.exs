defmodule Pinchflat.MediaWatch.ObserverTest do
  use ExUnit.Case, async: false

  alias Pinchflat.MediaWatch.MediaWatch, as: Watch
  alias Pinchflat.MediaWatch.Observation
  alias Pinchflat.MediaWatch.Observer

  test "the production HTTP fallback turns a connection failure into unknown" do
    original = Application.fetch_env(:pinchflat, :http_client)
    Application.delete_env(:pinchflat, :http_client)

    on_exit(fn ->
      case original do
        {:ok, client} -> Application.put_env(:pinchflat, :http_client, client)
        :error -> Application.delete_env(:pinchflat, :http_client)
      end
    end)

    # Keep the real HTTP request on loopback; no YouTube credentials or network are used.
    assert %Observation{availability: :unknown, reason: reason} =
             Observer.observe_youtube_api(%Watch{media_id: "e2e-test"},
               api_key: "local-fixture",
               connect_address: {127, 0, 0, 1}
             )

    assert is_binary(reason)
    assert reason =~ "HTTP request failed"
  end
end
