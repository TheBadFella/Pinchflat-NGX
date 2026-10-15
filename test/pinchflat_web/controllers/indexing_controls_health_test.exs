defmodule PinchflatWeb.IndexingControlsHealthTest do
  use PinchflatWeb.ConnCase
  import Pinchflat.SourcesFixtures
  import Phoenix.LiveViewTest
  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  test "new, edit and clone bind the native checkbox and not obsolete enabled state", %{conn: conn} do
    source = source_fixture(%{fast_index: true, download_subdirectory: "Saved/Owned"})

    for path <- ["/sources/new", "/sources/#{source.id}/edit", "/sources/new?template_id=#{source.id}"] do
      html = conn |> recycle() |> get(path) |> html_response(200)
      assert html =~ ~s(x-model="fastIndexingEnabled")
      assert html =~ "fastIndexingEnabled:"
      refute html =~ "fastIndexingEnabled = enabled"
    end
  end

  test "profile presets update checkbox state and dispatch actual input events", %{conn: conn} do
    html = conn |> get("/media_profiles/new") |> html_response(200)
    assert html =~ "$el.checked = presets[p]"
    refute html =~ "enabled = presets[p]"
  end

  test "shared custom select guards programmatic and already-open disabled selection" do
    html =
      render_component(&PinchflatWeb.CoreComponents.input/1,
        type: "select",
        id: "owned-picker",
        name: "owned",
        options: [{"One", "1"}],
        value: "1",
        rest: %{"x-bind:disabled" => "blocked"}
      )

    assert html =~ "if (this.$refs.input.disabled) return"
    assert html =~ "if (blocked || false) open = false"
  end

  test "health refresh is read-only and does not call missing timestamps broken", %{conn: conn} do
    source_fixture(%{custom_name: String.duplicate("Long name ", 25), fast_index: true})
    before = {Repo.all(Pinchflat.Sources.Source), Repo.all(Oban.Job)}
    {:ok, view, html} = live_isolated(conn, Pinchflat.Pages.SystemHealthLive)
    refute html =~ "Stale (&gt;24h)"
    refute html =~ "They may be stuck"
    assert html =~ "Unknown"
    assert html =~ "does not mean your library is broken"
    render_click(view, "refresh")
    assert before == {Repo.all(Pinchflat.Sources.Source), Repo.all(Oban.Job)}
  end

  test "disabled checkbox fallback follows native disabled semantics" do
    for type <- ["checkbox", "toggle"] do
      html =
        render_component(&PinchflatWeb.CoreComponents.input/1,
          type: type,
          name: "owned",
          id: "owned",
          checked: true,
          rest: %{"disabled" => true}
        )

      tags = Regex.scan(~r/<input\b[^>]*>/, html) |> List.flatten()
      assert Enum.count(tags, &String.match?(&1, ~r/\sdisabled(?:\s|>|=)/)) == 2

      html =
        render_component(&PinchflatWeb.CoreComponents.input/1,
          type: type,
          name: "owned",
          id: "owned",
          checked: true,
          rest: %{"x-bind:disabled" => "blocked"}
        )

      tags = Regex.scan(~r/<input\b[^>]*>/, html) |> List.flatten()
      assert Enum.count(tags, &String.contains?(&1, ~s(x-bind:disabled="blocked"))) == 2
    end
  end

  test "named custom selectors have distinct stable labels and listbox IDs" do
    for name <- ["preset_one", "preset_two"] do
      html =
        render_component(&PinchflatWeb.CoreComponents.input/1,
          type: "select",
          name: name,
          options: [{"One", "1"}],
          value: "1"
        )

      assert html =~ ~s(id="#{name}")
      assert html =~ ~s(aria-controls="#{name}-options")
      assert html =~ "this.$watch(model.value"
    end
  end
end
