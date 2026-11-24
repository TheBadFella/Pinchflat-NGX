defmodule PinchflatWeb.BulkSourceDeleteTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Sources.SourceDeletionWorker
  alias PinchflatWeb.Sources.SourceLive.IndexTableLive

  test "marks the selected sources for deletion, keeps their files and leaves others alone", %{conn: conn} do
    first = source_fixture()
    second = source_fixture()
    untouched = source_fixture()
    item = media_item_with_attachments(%{source_id: first.id})

    conn = post(conn, "/sources/delete_selected", %{"source_ids" => ["#{first.id}", "#{second.id}"]})

    assert redirected_to(conn) == "/sources"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Deleting 2 sources. Downloaded files are kept. This may take a while."

    for source <- [first, second] do
      assert Repo.reload!(source).marked_for_deletion_at
      assert_enqueued(worker: SourceDeletionWorker, args: %{"id" => source.id, "delete_files" => false})
    end

    refute Repo.reload!(untouched).marked_for_deletion_at
    refute_enqueued(worker: SourceDeletionWorker, args: %{"id" => untouched.id})
    assert File.exists?(item.media_filepath)
  end

  test "refuses the whole selection while a source has watch-protected videos", %{conn: conn} do
    profile = media_profile_fixture() |> Ecto.Changeset.change(watch_window_days: 14) |> Repo.update!()
    protected = source_fixture(media_profile_id: profile.id)
    other = source_fixture()
    path = Path.join(Application.fetch_env!(:pinchflat, :media_directory), "bulk-#{Ecto.UUID.generate()}.mp4")
    File.write!(path, "original")
    item = media_item_fixture(source_id: protected.id, media_filepath: path)
    {:ok, _watch} = Pinchflat.MediaWatch.enroll_on_first_completion(item, Repo.preload(protected, :media_profile))

    conn =
      post(conn, "/sources/delete_selected", %{
        "source_ids" => ["#{protected.id}", "#{other.id}"],
        "delete_files" => "true"
      })

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "End watch protection"
    refute Repo.reload!(protected).marked_for_deletion_at
    refute Repo.reload!(other).marked_for_deletion_at
    refute_enqueued(worker: SourceDeletionWorker)
    assert File.exists?(path)
  end

  test "deletes the downloaded files too when asked", %{conn: conn} do
    source = source_fixture()

    conn = post(conn, "/sources/delete_selected", %{"source_ids" => ["#{source.id}"], "delete_files" => "true"})

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Deleting 1 source and their downloaded files. This may take a while."

    assert Repo.reload!(source).marked_for_deletion_at
    assert_enqueued(worker: SourceDeletionWorker, args: %{"id" => source.id, "delete_files" => true})
  end

  test "rejects an empty or stale selection without deleting anything", %{conn: conn} do
    source = source_fixture()
    removed = source_fixture(marked_for_deletion_at: DateTime.utc_now())

    for params <- [%{}, %{"source_ids" => []}, %{"source_ids" => ["#{source.id}", "#{removed.id}"]}] do
      response = post(conn, "/sources/delete_selected", Map.put(params, "return_to", "/sources?type=videos"))

      assert redirected_to(response) == "/sources?type=videos"
      assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Could not delete the selection."
    end

    refute Repo.reload!(source).marked_for_deletion_at
    refute_enqueued(worker: SourceDeletionWorker)
  end

  test "reports the result as a toast on the sources page", %{conn: conn} do
    source = source_fixture()

    conn = post(conn, "/sources/delete_selected", %{"source_ids" => ["#{source.id}"]})
    html = conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)

    assert html =~ "Deleting 1 source. Downloaded files are kept."
    assert html =~ ~s|x-init="setTimeout(() =&gt; open = false, 5000)"|
    assert html =~ "theme-toast-stack"
  end

  test "asks for confirmation in a dialog that states how many sources will go", %{conn: conn} do
    first = source_fixture(custom_name: "First")
    second = source_fixture(custom_name: "Second")

    session = %{
      "initial_sort_key" => :custom_name,
      "initial_sort_direction" => :asc,
      "initial_view_mode" => :table,
      "results_per_page" => 10
    }

    {:ok, view, _html} = live_isolated(conn, IndexTableLive, session: session)

    assert has_element?(view, "#selected-source-actions button.theme-danger-button[disabled]", "Delete")

    render_click(view, "toggle_select_all")

    refute has_element?(view, "#selected-source-actions button.theme-danger-button[disabled]")
    view |> element("#selected-source-actions button.theme-danger-button") |> render_click()
    assert has_element?(view, "#delete-selected-sources-modal-title", "Delete 2 sources?")
    assert has_element?(view, "#delete-selected-sources-modal-names li", "First")
    assert has_element?(view, "#delete-selected-sources-modal-names li", "Second")
    assert has_element?(view, "#delete-selected-sources-modal", "Choose whether to keep the downloaded files.")
    assert has_element?(view, "#delete-selected-sources input[name='source_ids[]'][value='#{first.id}']")
    assert has_element?(view, "#delete-selected-sources input[name='source_ids[]'][value='#{second.id}']")
    assert has_element?(view, "#delete-selected-sources button[type=submit]:not([name])", "Delete Sources")

    assert has_element?(
             view,
             "#delete-selected-sources button[type=submit][name=delete_files][value=true]",
             "Delete Sources + Files"
           )

    refute render(view) =~ "data-confirm"

    # Cancelling empties the dialog, so a later open that doesn't reach the server can't post this selection.
    render_click(view, "cancel_delete")
    refute has_element?(view, "#delete-selected-sources input[name='source_ids[]']")
    assert has_element?(view, "#delete-selected-sources button[type=submit][disabled]", "Delete Sources")

    # The bulk buttons need a second click instead of a browser dialog.
    view |> element("#pause-selected-sources button") |> render_click()
    assert has_element?(view, ~s(#pause-selected-sources button[data-armed="true"]), "Pause 2?")
  end
end
