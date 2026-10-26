defmodule PinchflatWeb.Settings.BackupHTML do
  use PinchflatWeb, :html

  embed_templates "backup_html/*"

  def format_backup_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  def format_backup_size(bytes) when is_integer(bytes) and bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_backup_size(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  def format_backup_datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  def format_backup_datetime(_datetime), do: "-"
end
