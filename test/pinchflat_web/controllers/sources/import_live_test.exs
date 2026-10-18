defmodule PinchflatWeb.Sources.ImportLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.ProfilesFixtures

  alias PinchflatWeb.Sources.ImportLive

  setup do
    Pinchflat.Settings.set(onboarding: false)
    %{profile: media_profile_fixture()}
  end

  test "preview does no work and invalid URLs produce a visible failure", %{conn: conn, profile: profile} do
    {:ok, view, html} =
      live_isolated(conn, ImportLive,
        session: %{"urls" => ["https://youtube.com/watch"], "profile_id" => profile.id, "duplicates" => 0}
      )

    assert html =~ "Review sources"
    assert Repo.aggregate(Pinchflat.Sources.Source, :count) == 0
    view |> element("#confirm-import") |> render_click()
    html = render_async(view)
    assert html =~ "1 failed"
    assert html =~ "Import finished"
    assert Repo.aggregate(Pinchflat.Sources.Source, :count) == 0
  end

  test "a slow provider leaves the page responsive and cancel keeps the completed source without starting the next", %{
    conn: conn,
    profile: profile
  } do
    owner = self()

    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _output, _system_opts ->
      send(owner, {:provider_started, self()})

      receive do
        :finish ->
          {:ok,
           Jason.encode!(%{
             channel: "Fixture channel",
             channel_id: "UC_fixture",
             playlist_id: "PL_fixture",
             playlist_title: "Fixture playlist"
           })}
      after
        5_000 -> flunk("fixture provider was not released")
      end
    end)

    {:ok, view, _} =
      live_isolated(conn, ImportLive,
        session: %{
          "urls" => ["https://www.youtube.com/@first", "https://www.youtube.com/@second"],
          "profile_id" => profile.id,
          "duplicates" => 0
        }
      )

    view |> element("#confirm-import") |> render_click()
    assert_receive {:provider_started, provider}
    assert render(view) =~ "Checking: https://www.youtube.com/@first"
    view |> element("#cancel-import") |> render_click()
    send(provider, :finish)
    html = render_async(view)
    assert html =~ "1 added"
    assert html =~ "1 of 2 checked"
    assert html =~ "Import cancelled"
    assert Repo.aggregate(Pinchflat.Sources.Source, :count) == 1
  end

  test "a migration hold activated after preview prevents import", %{conn: conn, profile: profile} do
    previous = Application.get_env(:pinchflat, :postgres_migration_boot_held)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:pinchflat, :postgres_migration_boot_held),
        else: Application.put_env(:pinchflat, :postgres_migration_boot_held, previous)
    end)

    {:ok, view, _} =
      live_isolated(conn, ImportLive,
        session: %{"urls" => ["https://www.youtube.com/@first"], "profile_id" => profile.id, "duplicates" => 0}
      )

    Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
    html = view |> element("#confirm-import") |> render_click()
    assert html =~ "Import stopped for migration review"
    assert Repo.aggregate(Pinchflat.Sources.Source, :count) == 0
  end
end
