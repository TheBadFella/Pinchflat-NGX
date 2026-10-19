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

  test "selects preserve false values and responsive width classes" do
    html =
      render_component(&CoreComponents.input/1,
        type: "select",
        name: "enabled",
        value: false,
        options: [{"Yes", true}, {"No", false}],
        inputclass: "w-30 lg:w-60"
      )

    assert html =~ ~r/<input[^>]*type="hidden"[^>]*value="false"/
    [_, shell_classes] = Regex.run(~r/class="(theme-field-shell[^"\n]*)"/, html)
    classes = String.split(shell_classes)
    assert "w-30" in classes
    assert "lg:w-60" in classes
    refute "max-w-xl" in classes
  end
end
