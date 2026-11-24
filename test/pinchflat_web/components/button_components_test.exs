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

  test "dropdown menus stay hidden until the page script opens them" do
    html =
      render_component(&ButtonComponents.button_dropdown/1,
        text: "More actions",
        option: [%{inner_block: fn _, _ -> "Start all" end}]
      )

    assert html =~ ~r/<div[^>]*x-show="dropdownOpen"[^>]*x-cloak/
  end

  test "a dropdown trigger uses the styled tooltip when given one, and the browser title otherwise" do
    options = [%{inner_block: fn _, _ -> "Start all" end}]

    with_tooltip =
      render_component(&ButtonComponents.button_dropdown/1,
        icon_name: "hero-ellipsis-vertical-solid",
        aria_label: "More actions for Example",
        tooltip: "More actions",
        option: options
      )

    without_tooltip =
      render_component(&ButtonComponents.button_dropdown/1,
        icon_name: "hero-ellipsis-vertical-solid",
        aria_label: "More actions for Example",
        option: options
      )

    assert with_tooltip =~ ~s(role="tooltip")
    assert with_tooltip =~ ~s(popover="manual")
    assert with_tooltip =~ "More actions"
    refute with_tooltip =~ ~s(title="More actions for Example")
    assert with_tooltip =~ ~s(x-ref="trigger")

    refute without_tooltip =~ ~s(role="tooltip")
    assert without_tooltip =~ ~s(title="More actions for Example")
    assert without_tooltip =~ ~s(x-ref="trigger")
  end
end
