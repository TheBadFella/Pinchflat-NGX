defmodule PinchflatWeb.Sources.SourceLive.SourceEnableToggleTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Metadata.SourceMetadata
  alias PinchflatWeb.Sources.SourceLive.SourceEnableToggle

  describe "initial rendering" do
    test "renders a toggle in the on position if the source is enabled" do
      source = %{id: 1, enabled: true}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~
               ~s(<input type="checkbox" id="source_enable_toggle_foo_input" name="source[enabled]" value="true" checked)
    end

    test "renders the form with an id so LiveView can recover it on reconnect" do
      source = %{id: 1, enabled: true}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~ ~s(id="source_enable_toggle_foo_form")
    end

    test "renders a toggle in the off position if the source is disabled" do
      source = %{id: 1, enabled: false}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~
               ~s(<input type="checkbox" id="source_enable_toggle_foo_input" name="source[enabled]" value="true" class="peer sr-only")
    end

    test "renders unique ids for separate component instances of the same source" do
      source = %{id: 1, enabled: true}

      desktop_html = render_component(SourceEnableToggle, %{id: "source_1_enabled", source: source})
      mobile_html = render_component(SourceEnableToggle, %{id: "source_1_enabled_mobile", source: source})

      assert desktop_html =~ ~s(id="source_enable_toggle_source_1_enabled_input")
      assert mobile_html =~ ~s(id="source_enable_toggle_source_1_enabled_mobile_input")
    end

    test "renders when the source map includes a preloaded metadata struct" do
      source = %{
        id: 1,
        enabled: true,
        custom_name: "Indexed Channel",
        metadata: %SourceMetadata{id: 1, metadata_filepath: "/tmp/metadata.json.gz"}
      }

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~ ~s(name="source[enabled]")
      assert html =~ "Monitor Indexed Channel"
    end
  end
end
