defmodule PinchflatWeb.CoreComponentsInputTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CoreComponents

  test "standalone text inputs and textareas associate their labels with the input" do
    for type <- ["text", "textarea"] do
      html = render_component(&CoreComponents.input/1, type: type, name: "canary_url", label: "Canary URL", value: "")

      assert html =~ ~s(for="canary_url")
      assert html =~ ~s(id="canary_url")

      explicit =
        render_component(&CoreComponents.input/1,
          type: type,
          name: "canary_url",
          id: "custom-canary",
          label: "Canary URL",
          value: ""
        )

      assert explicit =~ ~s(for="custom-canary")
      assert explicit =~ ~s(id="custom-canary")
    end
  end
end
