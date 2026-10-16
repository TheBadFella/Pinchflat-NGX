defmodule PinchflatWeb.Pages.PageController do
  use PinchflatWeb, :controller
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Boot.PostJobStartupTasks
  alias Pinchflat.LegacyMigration
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  def home(%{method: "HEAD"} = conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, "")
  end

  def home(conn, params) do
    if LegacyMigration.legacy_migration_pending?() do
      render_migration_review_page(conn)
    else
      done_onboarding = params["onboarding"] == "0"
      force_onboarding = params["onboarding"] == "1"

      if done_onboarding, do: Settings.set(onboarding: false)

      if force_onboarding || Settings.get!(:onboarding) do
        render_onboarding_page(conn)
      else
        render_home_page(conn, params)
      end
    end
  end

  def confirm_migration_review(conn, _params) do
    if LegacyMigration.legacy_migration_pending?() do
      verification =
        if LegacyMigration.get_state().status == "pending_release",
          do: %{complete: true},
          else: LegacyMigration.get_or_run_verification()

      with %{complete: true} <- verification,
           :ok <- LegacyMigration.complete_review!(),
           :ok <- LegacyMigration.release_mutating_queues!() do
        PostJobStartupTasks.reschedule_missing_indexing_tasks()

        conn
        |> put_flash(:info, "Migration review confirmed. Your queue pause choices have been preserved.")
        |> redirect(to: ~p"/")
      else
        %{complete: false} ->
          conn
          |> put_flash(:error, "Finish library verification before confirming. Background work remains held.")
          |> redirect(to: ~p"/")

        {:error, _} ->
          message =
            if LegacyMigration.get_state().status == "pending_release",
              do:
                "Your review is confirmed, but background work could not finish resuming. Some queues may remain paused. Retry to finish.",
              else:
                "Could not confirm migration review. Check database permissions and try again. Background work remains held."

          conn
          |> put_flash(:error, message)
          |> redirect(to: ~p"/")
      end
    else
      redirect(conn, to: ~p"/")
    end
  end

  def rescan_migration_review(conn, _params) do
    if LegacyMigration.legacy_migration_pending?() do
      case LegacyMigration.start_verification() do
        {:ok, _} ->
          conn |> put_flash(:info, "Library verification is running.") |> redirect(to: ~p"/")

        {:error, _} ->
          conn
          |> put_flash(
            :error,
            "Could not start verification. Check config access, then retry. Background work remains held."
          )
          |> redirect(to: ~p"/")
      end
    else
      redirect(conn, to: ~p"/")
    end
  end

  defp render_migration_review_page(conn) do
    summary = LegacyMigration.get_or_run_verification()
    state = LegacyMigration.get_state()

    conn
    |> render(:migration_review,
      summary: summary,
      state: state,
      layout: {Layouts, :onboarding}
    )
  end

  defp render_home_page(conn, params) do
    downloaded_media_items = where(MediaQuery.new(), ^MediaQuery.downloaded())
    active_tab = tab_param(params, ~w(latest pending failed active-tasks downloaded job-queue system-health), "pending")
    setting = Settings.record()

    conn
    |> render(:home,
      active_tab: active_tab,
      latest_range: Map.take(params, ~w(range from to)),
      tab_href: fn tab -> ~p"/?#{[tab: tab]}" end,
      media_profile_count: Repo.aggregate(MediaProfile, :count, :id),
      source_count: Repo.aggregate(Source, :count, :id),
      media_item_size: Repo.aggregate(downloaded_media_items, :sum, :media_size_bytes),
      media_item_count: Repo.aggregate(downloaded_media_items, :count, :id),
      setting: setting
    )
  end

  defp render_onboarding_page(conn) do
    Settings.set(onboarding: true)

    conn
    |> render(:onboarding_checklist,
      media_profiles_exist: Repo.exists?(MediaProfile),
      sources_exist: Repo.exists?(Source),
      layout: {Layouts, :onboarding}
    )
  end

  defp tab_param(params, allowed_tabs, default_tab) do
    tab = params["tab"]

    if tab in allowed_tabs do
      tab
    else
      default_tab
    end
  end
end
