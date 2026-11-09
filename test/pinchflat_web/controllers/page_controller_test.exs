defmodule PinchflatWeb.PageControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.LegacyMigration
  alias Pinchflat.Settings

  describe "GET / when testing onboarding" do
    test "sets the onboarding setting to true when onboarding", %{conn: conn} do
      _conn = get(conn, ~p"/")
      assert Settings.get!(:onboarding)
    end

    test "displays the onboarding page when onboarding is forced", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/?onboarding=1&tab=latest")
      assert html_response(conn, 200) =~ "Welcome to Pinchflat"
      refute html_response(conn, 200) =~ ~s(href="/?tab=latest")
    end

    test "sets the onboarding setting to false if you pass the corrent query param", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert Settings.get!(:onboarding)

      _conn = get(conn, ~p"/?onboarding=0")
      refute Settings.get!(:onboarding)
    end

    test "displays the home page when not onboarding", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "MENU"
      assert html_response(conn, 200) =~ "Failed"
      assert html_response(conn, 200) =~ "Latest"
      assert html_response(conn, 200) =~ ~s(href="/?tab=latest")
    end

    test "defaults to Latest and preserves explicit tab links", %{conn: conn} do
      Settings.set(onboarding: false)

      default_conn = get(conn, ~p"/")
      assert default_conn.assigns.active_tab == "latest"

      invalid_conn = get(recycle(default_conn), ~p"/?tab=unknown")
      assert invalid_conn.assigns.active_tab == "latest"

      pending_conn = get(recycle(invalid_conn), ~p"/?tab=pending")
      assert pending_conn.assigns.active_tab == "pending"

      latest_conn = get(recycle(default_conn), ~p"/?tab=latest")
      assert latest_conn.assigns.active_tab == "latest"
    end

    test "restores the custom indexed range from the URL", %{conn: conn} do
      Settings.set(onboarding: false)
      item = Pinchflat.MediaFixtures.media_item_fixture(title: "Indexed in March")
      item |> Ecto.Changeset.change(inserted_at: ~U[2024-03-02 12:00:00Z]) |> Pinchflat.Repo.update!()

      conn = get(conn, ~p"/?tab=latest&range=custom&from=2024-03-01&to=2024-03-03")
      html = html_response(conn, 200)
      assert html =~ item.title
      assert html =~ ~s(value="2024-03-01")
      assert html =~ ~s(value="2024-03-03")
    end

    test "displays storage space protection banner when downloads are blocked", %{conn: conn} do
      Settings.set(onboarding: false)
      Settings.set(download_space_protection_enabled: true)
      Settings.set(download_space_protection_blocked: true)
      Settings.set(download_space_protection_blocked_location: "destination")
      Settings.set(download_space_protection_free_bytes: 5 * 1024 * 1024 * 1024)

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ "Downloads Paused: Storage Space Low"
      assert html =~ "Check storage and resume downloads"
      assert html =~ "destination"
    end
  end

  describe "legacy migration review flow" do
    setup do
      test_state_file =
        Path.join(
          System.tmp_dir!(),
          "test_page_migration_state_#{System.unique_integer([:positive])}.json"
        )

      Application.put_env(:pinchflat, :legacy_migration_state_path, test_state_file)

      pending_state = %{
        provenance: "legacy_pinchflat",
        status: "pending_review",
        detected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        original_max_version: 20_250_317_213_740,
        source_count: 3
      }

      File.write!(test_state_file, Jason.encode!(pending_state))
      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()
      LegacyMigration.verify_library()

      on_exit(fn ->
        for pid <- Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor),
            do: Task.Supervisor.terminate_child(Pinchflat.LegacyMigration.ScanSupervisor, pid)

        Application.delete_env(:pinchflat, :legacy_migration_state_path)
        File.rm(test_state_file)
      end)

      %{state_file: test_state_file}
    end

    test "renders migration review page when review is pending", %{conn: conn} do
      assert LegacyMigration.legacy_migration_pending?()

      conn = get(conn, ~p"/?tab=latest")
      html = html_response(conn, 200)

      assert html =~ "Welcome to Pinchflat-NGX"
      assert html =~ "Migration Review"
      assert html =~ "checking your existing library"
      assert html =~ "Database Records"
      assert html =~ "Verified on Disk"
      assert html =~ "Looks good, continue"
      assert html =~ "Re-scan Disk"
      refute html =~ ~s(href="/?tab=latest")
    end

    test "redirects other browser routes to root while review is pending", %{conn: conn} do
      conn = get(conn, ~p"/discovery")
      assert redirected_to(conn) == ~p"/"
    end

    test "rescan endpoint refreshes scan and redirects to root", %{conn: conn} do
      conn = post(conn, ~p"/migration/rescan")
      assert redirected_to(conn) == ~p"/"

      for pid <- Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
      end

      assert LegacyMigration.get_or_run_verification().complete
    end

    test "a running scan cannot be confirmed through a direct POST", %{conn: conn, state_file: path} do
      summary = LegacyMigration.verify_library() |> Map.put(:status, :running) |> Map.put(:complete, false)
      File.write!(path, Jason.encode!(%{provenance: "legacy_pinchflat", status: "pending_review", last_scan: summary}))

      {:ok, pid} =
        Task.Supervisor.start_child(Pinchflat.LegacyMigration.ScanSupervisor, fn ->
          receive do
            :finish -> :ok
          end
        end)

      try do
        conn = post(conn, ~p"/migration/confirm_review")
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Finish library verification"
        assert LegacyMigration.legacy_migration_pending?()
        assert LegacyMigration.start_verification() == {:ok, :already_running}
      after
        Task.Supervisor.terminate_child(Pinchflat.LegacyMigration.ScanSupervisor, pid)
      end

      conn = get(recycle(conn), ~p"/")
      assert html_response(conn, 200) =~ "Verification incomplete"
      assert html_response(conn, 200) =~ "scan stopped before finishing"
    end

    test "confirming review transitions state to completed and releases review hold", %{conn: conn} do
      assert LegacyMigration.legacy_migration_pending?()

      conn = post(conn, ~p"/migration/confirm_review")
      assert redirected_to(conn) == ~p"/"

      refute LegacyMigration.legacy_migration_pending?()
      assert LegacyMigration.get_state().status == "completed"

      # Next visit to root displays regular home or onboarding, not migration review
      Settings.set(onboarding: false)
      conn = get(recycle(conn), ~p"/")
      html = html_response(conn, 200)

      refute html =~ "Migration Review"
      assert html =~ "MENU"
    end

    @tag :sqlite_only
    test "a rejected completion write leaves review pending and shows an error", %{conn: conn} do
      Ecto.Adapters.SQL.query!(
        Pinchflat.Repo,
        "CREATE TEMP TRIGGER reject_review_confirmation BEFORE UPDATE OF status ON legacy_migration_records WHEN NEW.status='pending_release' BEGIN SELECT RAISE(ABORT, 'review write rejected'); END"
      )

      try do
        conn = post(conn, ~p"/migration/confirm_review")
        assert redirected_to(conn) == ~p"/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not confirm"
        assert LegacyMigration.legacy_migration_pending?()
        assert is_nil(LegacyMigration.get_state().confirmed_at)
      after
        Ecto.Adapters.SQL.query!(Pinchflat.Repo, "DROP TRIGGER reject_review_confirmation")
      end
    end

    @tag :sqlite_only
    test "release persistence failure retains approval and can be retried", %{conn: conn} do
      Ecto.Adapters.SQL.query!(
        Pinchflat.Repo,
        "CREATE TEMP TRIGGER reject_release_completion BEFORE UPDATE OF status ON legacy_migration_records WHEN NEW.status='completed' BEGIN SELECT RAISE(ABORT, 'release rejected'); END"
      )

      try do
        changed = post(conn, ~p"/migration/confirm_review")
        assert Phoenix.Flash.get(changed.assigns.flash, :error) =~ "review is confirmed"
        assert LegacyMigration.get_state().status == "pending_release"
        assert LegacyMigration.get_state().confirmed_at != nil
        html = get(recycle(changed), ~p"/") |> html_response(200)
        assert html =~ "Retry resuming work"
        assert html =~ "Some queues may remain paused"
      after
        Ecto.Adapters.SQL.query!(Pinchflat.Repo, "DROP TRIGGER reject_release_completion")
      end

      changed = post(recycle(conn), ~p"/migration/confirm_review")
      assert LegacyMigration.get_state().status == "completed"
      assert redirected_to(changed) == ~p"/"
    end

    test "API writes are held and reads remain available", %{conn: conn} do
      changed = post(conn, ~p"/api/media_profiles", %{})
      assert json_response(changed, 423)["error"] =~ "migration review"
      assert get(recycle(conn), ~p"/api/stats").status == 200
    end
  end

  describe "PostgreSQL transfer review gate" do
    setup do
      keys = [
        :postgres_migration_boot_held,
        :sqlite_migration_source,
        :basic_auth_username,
        :basic_auth_password,
        :oidc
      ]

      previous = Map.new(keys, &{&1, Application.get_env(:pinchflat, &1)})
      initial_onboarding = Settings.get!(:onboarding)
      Enum.each(keys, &Application.delete_env(:pinchflat, &1))

      on_exit(fn ->
        Settings.set(onboarding: initial_onboarding)

        Enum.each(previous, fn
          {key, nil} -> Application.delete_env(:pinchflat, key)
          {key, value} -> Application.put_env(:pinchflat, key, value)
        end)
      end)

      :ok
    end

    test "redirects the root before onboarding when a transfer is pending", %{conn: conn} do
      Settings.set(onboarding: false)
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
      initial_profiles = Repo.aggregate(Pinchflat.Profiles.MediaProfile, :count)
      initial_sources = Repo.aggregate(Pinchflat.Sources.Source, :count)

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/postgres_migration"

      page = conn |> recycle() |> get(~p"/postgres_migration") |> html_response(200)
      assert page =~ "PostgreSQL Migration"
      refute page =~ "Welcome to Pinchflat"

      refute Settings.get!(:onboarding)
      assert Repo.aggregate(Pinchflat.Profiles.MediaProfile, :count) == initial_profiles
      assert Repo.aggregate(Pinchflat.Sources.Source, :count) == initial_sources
    end

    test "blocks direct onboarding pages and query-parameter bypasses" do
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)

      for path <- [~p"/sources/new", ~p"/media_profiles/new", ~p"/discovery", "/?onboarding=0", "/?onboarding=1"] do
        assert get(build_conn(), path) |> redirected_to() == ~p"/postgres_migration"
      end
    end

    test "blocks direct library creation while a transfer is pending" do
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
      initial_profiles = Repo.aggregate(Pinchflat.Profiles.MediaProfile, :count)
      initial_sources = Repo.aggregate(Pinchflat.Sources.Source, :count)

      profile_conn =
        post(build_conn(), ~p"/media_profiles", %{
          "media_profile" => %{"name" => "Blocked target", "output_path_template" => "{{id}}.{{ext}}"}
        })

      assert redirected_to(profile_conn) == ~p"/postgres_migration"
      assert Repo.aggregate(Pinchflat.Profiles.MediaProfile, :count) == initial_profiles

      profile = Pinchflat.ProfilesFixtures.media_profile_fixture()

      source_conn =
        post(build_conn(), ~p"/sources", %{
          "source" => %{
            "media_profile_id" => profile.id,
            "collection_type" => "channel",
            "original_url" => "https://www.youtube.com/@pinchflattest"
          }
        })

      assert redirected_to(source_conn) == ~p"/postgres_migration"
      assert Repo.aggregate(Pinchflat.Sources.Source, :count) == initial_sources
    end

    test "a configured SQLite source alone does not activate PostgreSQL routing", %{conn: conn} do
      Application.put_env(:pinchflat, :sqlite_migration_source, "/tmp/does-not-exist.db")
      Settings.set(onboarding: false)

      assert html_response(get(conn, ~p"/"), 200) =~ "MENU"
      assert get(build_conn(), ~p"/sources").status == 200
    end

    test "authentication is checked before the transfer gate" do
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)
      Application.put_env(:pinchflat, :basic_auth_username, "operator")
      Application.put_env(:pinchflat, :basic_auth_password, "fixture-password")

      assert get(build_conn(), ~p"/").status == 401

      authorized =
        build_conn()
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("operator", "fixture-password"))
        |> get(~p"/")

      assert redirected_to(authorized) == ~p"/postgres_migration"
    end

    test "SSO login stays reachable and precedes migration review" do
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)

      Application.put_env(:pinchflat, :oidc,
        issuer: "https://identity.example.test",
        client_id: "fixture",
        client_secret: "fixture"
      )

      login = get(build_conn(), ~p"/auth/login")
      assert login.status in [200, 302]
      if login.status == 302, do: refute(redirected_to(login) == ~p"/postgres_migration")

      assert redirected_to(get(build_conn(), ~p"/")) == "/auth/login?redirect_to=%2F"

      session = Plug.Test.init_test_session(build_conn(), %{PinchflatWeb.OIDC.session_key() => %{sub: "fixture"}})
      assert redirected_to(get(session, ~p"/")) == ~p"/postgres_migration"
    end
  end

  describe "when legacy and PostgreSQL reviews are both pending" do
    setup do
      test_state_file = Path.join(System.tmp_dir!(), "test_postgres_gate_#{System.unique_integer([:positive])}.json")
      Application.put_env(:pinchflat, :legacy_migration_state_path, test_state_file)

      File.write!(
        test_state_file,
        Jason.encode!(%{
          provenance: "legacy_pinchflat",
          status: "pending_review",
          detected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          original_max_version: 20_250_317_213_740,
          source_count: 3
        })
      )

      Pinchflat.LegacyMigrationFixtures.pending_migration_fixture()
      LegacyMigration.verify_library()
      Application.put_env(:pinchflat, :postgres_migration_boot_held, true)

      on_exit(fn ->
        for pid <- Task.Supervisor.children(Pinchflat.LegacyMigration.ScanSupervisor),
            do: Task.Supervisor.terminate_child(Pinchflat.LegacyMigration.ScanSupervisor, pid)

        Application.delete_env(:pinchflat, :legacy_migration_state_path)
        Application.delete_env(:pinchflat, :postgres_migration_boot_held)
        File.rm(test_state_file)
      end)

      :ok
    end

    test "PostgreSQL review takes priority and migration URLs do not loop" do
      assert LegacyMigration.legacy_migration_pending?()

      assert redirected_to(get(build_conn(), ~p"/")) == ~p"/postgres_migration"
      assert redirected_to(get(build_conn(), ~p"/discovery")) == ~p"/postgres_migration"

      page = get(build_conn(), ~p"/postgres_migration") |> html_response(200)
      assert page =~ "PostgreSQL Migration"
      refute page =~ "Migration Review"

      response = post(build_conn(), ~p"/postgres_migration/start")
      assert redirected_to(response) == ~p"/postgres_migration"
      assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Stop the old instance"
    end
  end

  describe "GET /activity when testing operational tabs" do
    setup do
      Settings.set(onboarding: false)
      :ok
    end

    test "renders Active Tasks by default", %{conn: conn} do
      conn = get(conn, ~p"/activity")
      html = html_response(conn, 200)

      assert conn.assigns.active_tab == "active-tasks"
      assert html =~ "Activity"
      assert active_page_section(html) =~ "<span>Active Tasks</span>"
    end

    test "renders the Job Queue and System Health tabs", %{conn: conn} do
      for {tab, title} <- [{"job-queue", "Job Queue"}, {"system-health", "System Health"}] do
        conn = get(recycle(conn), ~p"/activity?#{[tab: tab]}")
        html = html_response(conn, 200)

        assert conn.assigns.active_tab == tab
        assert active_page_section(html) =~ "<span>#{title}</span>"
      end
    end

    test "redirects legacy operational home links to Activity", %{conn: conn} do
      for tab <- ~w(active-tasks job-queue system-health) do
        conn = get(recycle(conn), ~p"/?#{[tab: tab]}")
        assert redirected_to(conn) == ~p"/activity?#{[tab: tab]}"
      end
    end

    test "Home no longer renders the operational tabs", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "Active Tasks"
      refute html =~ "Job Queue"
      refute html =~ "System Health"
    end

    test "Basic Auth protects Activity like Home" do
      Application.put_env(:pinchflat, :basic_auth_username, "operator")
      Application.put_env(:pinchflat, :basic_auth_password, "fixture-password")

      on_exit(fn ->
        Application.delete_env(:pinchflat, :basic_auth_username)
        Application.delete_env(:pinchflat, :basic_auth_password)
      end)

      assert get(build_conn(), ~p"/activity").status == 401
      assert get(build_conn(), ~p"/").status == 401
    end
  end

  defp active_page_section(html) do
    assert [sections] =
             Regex.run(~r/<nav\b[^>]*aria-label="Page sections"[^>]*>(.*?)<\/nav>/s, html, capture: :all_but_first)

    assert [[current_link]] = Regex.scan(~r/<a\b[^>]*aria-current="page"[^>]*>.*?<\/a>/s, sections)
    current_link
  end
end
