defmodule PinchflatWeb.Helpers.MediaCleanupHelpers do
  @moduledoc "Explains the existing automatic deletion rules at manual download controls."

  alias Pinchflat.Sources.Source

  @doc "Returns whether an unprotected item is before the source's inclusive download cutoff."
  def cutoff_cleanup?(%{prevent_culling: true}, _source), do: false
  def cutoff_cleanup?(%{uploaded_at: nil}, _source), do: false

  def cutoff_cleanup?(%{uploaded_at: %DateTime{} = uploaded_at}, source) do
    case Source.effective_download_cutoff_date(source) do
      %Date{} = cutoff -> Date.compare(DateTime.to_date(uploaded_at), cutoff) == :lt
      nil -> false
    end
  end

  @doc "Explains which publication date falls before which source download cutoff date."
  def cutoff_cleanup_warning(item, source) do
    today = Date.utc_today()
    published_on = item.uploaded_at |> DateTime.to_date() |> Date.to_iso8601()
    cutoff = source |> Source.effective_download_cutoff_date(today) |> Date.to_iso8601()

    cutoff_description =
      if is_integer(source.download_cutoff_days) and source.download_cutoff_days > 0 do
        "this source's rolling download cutoff of #{cutoff} " <>
          "(last #{source.download_cutoff_days} days on #{Date.to_iso8601(today)})"
      else
        "this source's download cutoff date of #{cutoff}"
      end

    "This video was published on #{published_on}, before #{cutoff_description}. " <>
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
