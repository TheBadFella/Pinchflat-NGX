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
      assert html_response(latest_conn, 200) =~ "No media indexed in this time frame."
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
end
