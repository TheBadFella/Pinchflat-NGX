defmodule PinchflatWeb.DeploymentUrl do
  @moduledoc """
  Resolves the browser-facing base URL for bookmarklets, userscripts and links.
  """

  use PinchflatWeb, :verified_routes

  @doc """
  Returns the configured external base URL when set, otherwise the request URL
  without a trailing slash.
  """
  @spec base_url(Plug.Conn.t()) :: String.t()
  def base_url(%Plug.Conn{} = conn) do
    conn |> url(~p"/") |> String.trim_trailing("/") |> base_url()
  end

  @spec base_url(String.t() | nil) :: String.t()
  def base_url(request_base_url) do
    setting = Pinchflat.Settings.record()

    cond do
      setting.external_base_url && String.trim(setting.external_base_url) != "" ->
        setting.external_base_url |> String.trim() |> String.trim_trailing("/")

      is_binary(request_base_url) && request_base_url != "" ->
        String.trim_trailing(request_base_url, "/")

      true ->
        PinchflatWeb.Endpoint.url() |> String.trim_trailing("/")
    end
  end
end
