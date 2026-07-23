defmodule PinchflatWeb.Settings.ReconciliationHTML do
  use PinchflatWeb, :html

  embed_templates "reconciliation_html/*"

  def mode_options do
    [
      {"Local only", "local"},
      {"Online mode", "online"},
      {"Full sync", "full"}
    ]
  end

  def source_options(sources) do
    [{"All sources", "all"}] ++ Enum.map(sources, fn source -> {source.custom_name, to_string(source.id)} end)
  end

  def plan_scope_name(%{source: %{custom_name: name}}) when is_binary(name), do: name
  def plan_scope_name(_plan), do: "All sources"

  def plan_status_class(:ready), do: "text-blue-400"
  def plan_status_class(:applied), do: "text-green-400"
  def plan_status_class(:failed), do: "text-red-400"
  def plan_status_class(_status), do: "text-bodydark"

  def humanize_mode(:local), do: "Local only"
  def humanize_mode(:online), do: "Online mode"
  def humanize_mode(:full), do: "Full sync"
  def humanize_mode(other), do: to_string(other)
end
