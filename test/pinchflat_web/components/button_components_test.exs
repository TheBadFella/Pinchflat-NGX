defmodule PinchflatWeb.ButtonComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PinchflatWeb.CustomComponents.ButtonComponents

  test "enabled navigation actions render one link without a nested button" do
    html =
      render_component(&ButtonComponents.button/1,
        href: "/settings/resume_downloads",
        method: "post",
        inner_block: [%{inner_block: fn _, _ -> "Resume downloads" end}]
      )

    assert html =~ "<a"
    assert html =~ ~s(data-method="post")
    assert html =~ ~s(data-to="/settings/resume_downloads")
    assert html =~ "data-csrf="
    refute html =~ "<button"
  end

  test "disabled navigation actions cannot follow their destination" do
    button =
      render_component(&ButtonComponents.button/1,
        href: "/sources/new",
        disabled: true,
        inner_block: [%{inner_block: fn _, _ -> "Create Source" end}]
      )

    icon =
      render_component(&ButtonComponents.icon_button/1,
        href: "/sources/new",
        disabled: true,
        icon_name: "hero-plus",
        tooltip: "Create Source"
      )

    for html <- [button, icon] do
      assert html =~ "<button"
      assert html =~ "disabled"
      refute html =~ ~s(href="/sources/new")
    end
  end
end
