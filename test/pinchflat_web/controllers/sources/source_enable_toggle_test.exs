defmodule PinchflatWeb.Sources.SourceLive.SourceEnableToggleTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PinchflatWeb.Sources.SourceLive.SourceEnableToggle

  describe "initial rendering" do
    test "renders a toggle in the on position if the source is enabled" do
      source = %{id: 1, enabled: true}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~ ~s(<input type="checkbox" id="source_1_enabled_input" name="source[enabled]" value="true" checked)
    end

    test "renders a toggle in the off position if the source is disabled" do
      source = %{id: 1, enabled: false}

      html = render_component(SourceEnableToggle, %{id: :foo, source: source})

      assert html =~
               ~s(<input type="checkbox" id="source_1_enabled_input" name="source[enabled]" value="true" class="peer sr-only")
    end
  end
end
