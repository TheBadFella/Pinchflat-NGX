defmodule PinchflatWeb.Sources.BulkCutoffController do
  use PinchflatWeb, :controller

  alias Pinchflat.Sources.BulkCutoff
  alias PinchflatWeb.Sources.SourceHTML

  def preview(conn, params) do
    ids = params["source_ids"]

    with {:ok, value} <- cutoff_value(params),
         {:ok, preview} <- BulkCutoff.preview(ids, value) do
      render_confirmation(conn, ids, value, preview, params)
    else
      {:error, reason} -> reject_preview(conn, reason, params)
    end
  end

  def apply(conn, %{"token" => token} = params) when is_binary(token) do
    with {:ok, {ids, value, fingerprint, removable}} <-
           Phoenix.Token.verify(conn, "bulk-source-cutoff", token, max_age: 900),
         {:ok, preview} <- BulkCutoff.preview(ids, value),
         :ok <- same_removable(preview, removable, conn, ids, value, params),
         {:ok, sources} <- BulkCutoff.apply_preview(ids, value, fingerprint) do
      noun = if length(sources) == 1, do: "source", else: "sources"

      conn
      |> put_flash(:info, "Download cutoff updated for #{length(sources)} selected #{noun}.")
      |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
    else
      {:changed, conn} -> conn
      {:error, reason} -> reject_preview(conn, reason, params)
      _ -> reject_preview(conn, :stale_preview, params)
    end
  end

  def apply(conn, params), do: reject_preview(conn, :stale_preview, params)

  @doc """
  Applies a download cutoff from the sources list. It goes straight through unless
  the new date makes downloaded items eligible for removal by scheduled retention;
  then the confirmation page shows those counts first. Problems such as an index
  cutoff later than the new date come back as an error message and change nothing.
  """
  def apply_now(conn, params) do
    ids = params["source_ids"]

    with {:ok, value} <- cutoff_value(params),
         {:ok, preview} <- BulkCutoff.preview(ids, value) do
      if preview.removable > 0,
        do: render_confirmation(conn, ids, value, preview, params),
        else: apply_without_confirmation(conn, ids, value, preview, params)
    else
      {:error, reason} -> reject_preview(conn, reason, params)
    end
  end

  # The sources list sends a mode with a date or a number of days; older forms send only a date.
  defp cutoff_value(%{"cutoff_mode" => "days"} = params),
    do: {:ok, "days:" <> String.trim(params["cutoff_days"] || "")}

  defp cutoff_value(%{"cutoff_mode" => "none"}), do: {:ok, ""}

  defp cutoff_value(%{"cutoff_mode" => "date"} = params) do
    case String.trim(params["cutoff_date"] || "") do
      "" -> {:error, :missing_cutoff_date}
      date -> {:ok, date}
    end
  end

  defp cutoff_value(params), do: {:ok, params["cutoff_date"]}

  defp apply_without_confirmation(conn, ids, value, preview, params) do
    case BulkCutoff.apply_preview(ids, value, preview.fingerprint) do
      {:ok, sources} ->
        conn
        |> put_flash(:info, applied_message(sources, preview))
        |> redirect(to: SourceHTML.source_list_path(params["return_to"]))

      {:error, reason} ->
        reject_preview(conn, reason, params)
    end
  end

  defp same_removable(%{removable: removable}, removable, _conn, _ids, _value, _params), do: :ok

  defp same_removable(preview, _removable, conn, ids, value, params) do
    {:changed, render_confirmation(conn, ids, value, preview, Map.put(params, "count_changed", true))}
  end

  defp render_confirmation(conn, ids, value, preview, params) do
    token = Phoenix.Token.sign(conn, "bulk-source-cutoff", {ids, value, preview.fingerprint, preview.removable})

    conn
    |> put_view(html: SourceHTML)
    |> render(:bulk_cutoff,
      preview: preview,
      token: token,
      count_changed: params["count_changed"] == true,
      return_to: SourceHTML.source_list_path(params["return_to"])
    )
  end

  defp applied_message(sources, %{cutoff: nil}) do
    "Download cutoff removed for #{length(sources)} #{source_noun(sources)}."
  end

  defp applied_message(sources, %{rolling_days: days}) when is_integer(days) do
    "Download cutoff set to the last #{days} days for #{length(sources)} #{source_noun(sources)}."
  end

  defp applied_message(sources, %{cutoff: cutoff}) do
    "Download cutoff set to #{Date.to_iso8601(cutoff)} for #{length(sources)} #{source_noun(sources)}."
  end

  defp source_noun([_one]), do: "source"
  defp source_noun(_sources), do: "sources"

  defp reject_preview(conn, reason, params) do
    message =
      case reason do
        :invalid_cutoff ->
          "Enter a valid cutoff date in YYYY-MM-DD format or a rolling window of 1 day or more, " <>
            "or choose No cutoff."

        :missing_cutoff_date ->
          "Pick a cutoff date, or choose No cutoff to remove the cutoff. No sources were changed."

        {:index_cutoff_after, conflicts} ->
          index_cutoff_message(conflicts)

        :invalid_source ->
          "The cutoff conflicts with a selected source's indexing cutoff or settings. Review the sources and try again."

        :invalid_selection ->
          "Select between 1 and #{Pinchflat.Sources.selection_limit()} available sources " <>
            "before previewing the cutoff."

        _ ->
          "The sources changed or the preview expired. Select the sources and preview the cutoff again."
      end

    conn |> put_flash(:error, message) |> redirect(to: SourceHTML.source_list_path(params["return_to"]))
  end

  # A download cutoff earlier than a source's index cutoff would never be reached, so name those sources and dates.
  defp index_cutoff_message(conflicts) do
    latest = conflicts |> Enum.map(fn {_name, date} -> date end) |> Enum.max(Date)

    listed =
      conflicts
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {name, date} -> "#{name} (#{Date.to_iso8601(date)})" end)

    more = if length(conflicts) > 3, do: " and #{length(conflicts) - 3} more", else: ""

    "Nothing changed. The download cutoff can't be earlier than a source's index cutoff: " <>
      "#{listed}#{more}. Choose #{Date.to_iso8601(latest)} or later, or change those index cutoffs first."
  end
end
