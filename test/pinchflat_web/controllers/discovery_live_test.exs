defmodule PinchflatWeb.DiscoveryLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Discovery
  alias Pinchflat.Discovery.Suggestion
  alias Pinchflat.Settings
  alias PinchflatWeb.DiscoveryLive

  @channel_id "UC" <> String.duplicate("a", 22)

  test "renders Channel Discovery and the empty state when connected", %{conn: conn} do
    {:ok, view, html} = live(conn, "/discovery")

    assert is_pid(view.pid)
    assert html =~ "Channel Discovery"
    assert html =~ "No channel suggestions yet"
  end

  test "renders the explicit disabled scheduled state", %{conn: conn} do
    assert {:ok, false} = Settings.set(channel_discovery_enabled: false)

    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    assert has_element?(view, ~s(#discovery-status-panel[data-discovery-enabled="false"]))
    assert has_element?(view, ~s([data-setting="channel_discovery_enabled"]), "Disabled")
  end

  test "refreshes suggestions created after mount", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    assert has_element?(view, "#discovery-empty")

    suggestion = suggestion_fixture()

    view
    |> element("#discovery-refresh")
    |> render_click()

    assert has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id}")
    assert has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id} dd", "Fixture evidence")
  end

  test "dismisses and restores a validated suggestion through the live view", %{conn: conn} do
    suggestion = suggestion_fixture()
    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    assert has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id}")
    assert has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id} dd", "Fixture evidence")

    view
    |> element("#dismiss-suggestion-#{suggestion.external_channel_id}")
    |> render_click()

    refute has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id}")
    assert has_element?(view, "#dismissed-#{suggestion.external_channel_id}")

    view
    |> element("#restore-suggestion-#{suggestion.external_channel_id}")
    |> render_click()

    assert has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id}")
    refute has_element?(view, "#dismissed-#{suggestion.external_channel_id}")
  end

  test "accepting a suggestion redirects to a channel source form", %{conn: conn} do
    original_url = "https://www.youtube.com/channel/#{@channel_id}"
    suggestion = suggestion_fixture(%{canonical_url: original_url})
    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#accept-suggestion-#{suggestion.external_channel_id}")
             |> render_click()

    uri = URI.parse(to)
    assert uri.path == "/sources/new"
    assert %{"original_url" => ^original_url, "source_type" => "channel"} = URI.decode_query(uri.query || "")
  end

  test "accepting an invalid prefill still uses normal source validation", %{conn: conn} do
    invalid_url = "https://www.youtube.com/watch"
    suggestion = suggestion_fixture(%{canonical_url: invalid_url})
    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#accept-suggestion-#{suggestion.external_channel_id}")
             |> render_click()

    assert html_response(get(conn, to), 200) =~ invalid_url

    response =
      post(conn, ~p"/sources",
        source: %{
          original_url: invalid_url,
          source_type: "channel",
          media_profile_id: media_profile_fixture().id
        }
      )
      |> html_response(200)

    assert response =~ "must be a channel, playlist, or single video URL"
    assert response =~ invalid_url
  end

  test "queues a scan without running external commands", %{conn: conn} do
    deny(YtDlpRunnerMock, :run, 5)

    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    html = view |> element("#discovery-scan") |> render_click()

    assert html =~ ~s(data-status="queued")
    assert html =~ "Scan queued."
    assert [%Oban.Job{state: "available"}] = all_enqueued(worker: Pinchflat.Discovery.Worker)

    html = render_click(view, "scan")
    assert html =~ ~s(data-status="busy")
    assert html =~ "Scan in progress."
  end

  test "updates suggestions and status from a channel discovery completion broadcast", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, DiscoveryLive, session: %{})

    suggestion = suggestion_fixture(%{channel_name: "Broadcast fixture"})
    refute has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id}")

    assert :ok = Discovery.broadcast_completion(%{status: :completed, inserted_count: 1})

    html = render(view)
    assert html =~ ~s(data-status="completed")
    assert html =~ "Scan completed. 1 new suggestion(s) added."
    assert has_element?(view, "#discovery-suggestion-#{suggestion.external_channel_id}", "Broadcast fixture")
  end

  defp suggestion_fixture(attrs \\ %{}) do
    {:ok, %Suggestion{} = suggestion} =
      Discovery.upsert_suggestion(
        Map.merge(
          %{
            external_channel_id: @channel_id,
            canonical_url: "https://www.youtube.com/channel/#{@channel_id}",
            channel_name: "Fixture channel",
            evidence: "Fixture evidence",
            score: 8
          },
          attrs
        )
      )

    suggestion
  end
end
