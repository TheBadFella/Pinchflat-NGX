defmodule PinchflatWeb.BrowserUserscripts do
  @moduledoc false

  @youtube_quick_add_path "priv/browser_userscripts/youtube-quick-add-source.user.js"
  @youtube_quick_add_route "/browser/userscripts/youtube-quick-add-source.user.js"

  @doc false
  def youtube_quick_add_route, do: @youtube_quick_add_route

  @doc """
  Returns the YouTube quick-add userscript with `PINCHFLAT_BASE`, `@match` and `@connect` set from `base_url`.
  """
  @spec youtube_quick_add_source(String.t()) :: String.t()
  def youtube_quick_add_source(base_url) when is_binary(base_url) do
    base_url = String.trim_trailing(base_url, "/")
    base_js = Jason.encode!(base_url)
    # Userscript managers expect a bare host name for @connect
    base_host = URI.parse(base_url).host || base_url
    template_path = Application.app_dir(:pinchflat, @youtube_quick_add_path)

    template_path
    |> File.read!()
    |> String.replace("__PINCHFLAT_BASE_JS__", base_js, [:global])
    |> String.replace("__PINCHFLAT_HOST__", base_host, [:global])
    |> String.replace("__PINCHFLAT_BASE__", base_url, [:global])
  end
end
