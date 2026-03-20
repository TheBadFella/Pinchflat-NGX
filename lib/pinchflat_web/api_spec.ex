defmodule PinchflatWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3.0 specification for the Pinchflat API.
  Collects operations from controller @operation decorators.
  """

  alias OpenApiSpex.{Info, OpenApi, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Pinchflat API",
        version: "1.0.0",
        description: "API for accessing Pinchflat media management data"
      },
      servers: [
        %Server{
          url: "/",
          description: "Current server"
        }
      ],
      # Paths will be populated by OpenApiSpex.Plug.PutApiSpec from router + controller operations
      paths: collect_paths()
    }
    # resolve_schema_modules/1 processes schema references and builds the full spec
    |> OpenApiSpex.resolve_schema_modules()
  end

  # Collect all paths from routed controllers with @operation decorators
  defp collect_paths do
    PinchflatWeb.Router.__routes__()
    |> Enum.filter(fn route -> has_operation?(route) end)
    |> Enum.reject(&html_only_action?/1)
    |> Enum.reduce(%{}, fn route, acc ->
      path = route_to_path(route.path)
      method = verb_to_operation_key(route.verb)

      case {method, get_operation(route.plug, route.plug_opts)} do
        {nil, _operation} -> acc
        {_method, nil} -> acc
        {method, operation} -> Map.update(acc, path, %{method => operation}, &Map.put(&1, method, operation))
      end
    end)
    |> Enum.into(%{}, fn {path, operations} ->
      path_item = struct(OpenApiSpex.PathItem, operations)
      {path, path_item}
    end)
  end

  defp route_to_path(path) do
    path
    |> String.replace(~r/:([^\/]+)/, "{\\1}")
  end

  defp verb_to_operation_key(verb) do
    case String.downcase(to_string(verb)) do
      "delete" -> :delete
      "get" -> :get
      "head" -> :head
      "options" -> :options
      "patch" -> :patch
      "post" -> :post
      "put" -> :put
      "trace" -> :trace
      _ -> nil
    end
  end

  defp html_only_action?(route) do
    # Only filter HTML-only actions from browser controllers (not API controllers)
    # API controllers are in the PinchflatWeb.Api namespace
    is_api_controller = String.starts_with?(Atom.to_string(route.plug), "Elixir.PinchflatWeb.Api.")

    if is_api_controller do
      false
    else
      # Filter HTML-only actions based on controller
      # Note: Some browser controllers have dual-format actions that support both HTML and JSON
      controller = route.plug
      action = route.plug_opts

      cond do
        # SourceController: force_* actions are HTML-only redirects
        controller == PinchflatWeb.Sources.SourceController and
            action in [
              :new,
              :edit,
              :force_download_pending,
              :force_redownload,
              :force_index,
              :force_metadata_refresh,
              :sync_files_on_disk
            ] ->
          true

        # MediaItemController: all actions except :stream are HTML-only
        controller == PinchflatWeb.MediaItems.MediaItemController and
            action in [:show, :edit, :update, :delete, :force_download] ->
          true

        true ->
          false
      end
    end
  end

  defp has_operation?(route) do
    Code.ensure_loaded?(route.plug) and function_exported?(route.plug, :open_api_operation, 1)
  end

  defp get_operation(plug, plug_opts) do
    if function_exported?(plug, :open_api_operation, 1) do
      try do
        plug.open_api_operation(plug_opts)
      rescue
        _ -> nil
      end
    else
      nil
    end
  end
end
