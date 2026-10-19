defmodule PinchflatWeb.Helpers.MediaCleanupHelpers do
  @moduledoc "Explains the existing automatic deletion rules at manual download controls."

  @doc "Returns whether an unprotected item is before the source's inclusive download cutoff."
  def cutoff_cleanup?(%{prevent_culling: true}, _source), do: false
  def cutoff_cleanup?(_item, %{download_cutoff_date: nil}), do: false
  def cutoff_cleanup?(%{uploaded_at: nil}, _source), do: false

  def cutoff_cleanup?(%{uploaded_at: %DateTime{} = uploaded_at}, %{download_cutoff_date: cutoff}) do
    Date.compare(DateTime.to_date(uploaded_at), cutoff) == :lt
  end

  @doc "Explains which publication date falls before which source download cutoff date."
  def cutoff_cleanup_warning(item, source) do
    published_on = item.uploaded_at |> DateTime.to_date() |> Date.to_iso8601()
    cutoff = Date.to_iso8601(source.download_cutoff_date)

    "This video was published on #{published_on}, before this source's download cutoff date of #{cutoff}. " <>
      "Its downloaded files can be deleted at the next scheduled cleanup, even before the retention period ends."
  end

  @doc "Returns the manual download confirmation, including cutoff cleanup consequences when applicable."
  def download_confirmation(item, source, prompt \\ "Force a download of this video?") do
    if cutoff_cleanup?(item, source) do
      prompt <>
        " " <>
        cutoff_cleanup_warning(item, source) <>
        " To keep it, cancel and enable Prevent Automatic Deletion on the video's Edit page first."
    else
      prompt
    end
  end
end
