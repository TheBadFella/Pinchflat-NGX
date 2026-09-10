defmodule Pinchflat.Media.DownloadState do
  @moduledoc """
  Pure transitions for durable media download prevention and error state.

  `prevent_download` remains the compatibility flag used by existing queries,
  while these transitions keep its origin and the latest failure classification
  explicit.
  """

  alias Pinchflat.Media.MediaItem

  @doc """
  Returns the changes needed to apply a download state transition.

  Supported events are `:policy_block`, `:policy_allowed`, `:success`,
  `{:failure, :transient | :permanent, force?}`, and
  `{:manual, prevented?}`.
  """
  def transition(%MediaItem{} = media_item, :policy_block) do
    case media_item.download_prevented_reason do
      reason when reason in [:manual, :error] -> %{}
      nil when media_item.prevent_download -> %{}
      _ -> %{prevent_download: true, download_prevented_reason: :policy}
    end
  end

  def transition(%MediaItem{} = media_item, :policy_allowed) do
    if media_item.download_prevented_reason == :policy do
      %{prevent_download: false, download_prevented_reason: nil}
    else
      %{}
    end
  end

  def transition(%MediaItem{} = media_item, {:failure, :transient, force?}) do
    if force? and media_item.download_prevented_reason == :error do
      # A forced attempt must not erase a permanent block before it succeeds.
      %{error_type: :permanent}
    else
      %{error_type: :transient}
    end
  end

  def transition(%MediaItem{} = media_item, {:failure, :permanent, _force?}) do
    attrs = %{error_type: :permanent}

    if media_item.download_prevented_reason in [:manual, :policy, :error] do
      attrs
    else
      Map.merge(attrs, %{prevent_download: true, download_prevented_reason: :error})
    end
  end

  def transition(%MediaItem{} = media_item, :success) do
    attrs = %{error_type: nil, last_error: nil}

    if media_item.download_prevented_reason == :error do
      Map.merge(attrs, %{prevent_download: false, download_prevented_reason: nil})
    else
      attrs
    end
  end

  def transition(%MediaItem{}, {:manual, true}) do
    %{
      error_type: nil,
      last_error: nil,
      prevent_download: true,
      download_prevented_reason: :manual
    }
  end

  def transition(%MediaItem{download_prevented_reason: :manual}, {:manual, false}) do
    %{
      error_type: nil,
      last_error: nil,
      prevent_download: false,
      download_prevented_reason: nil
    }
  end

  def transition(%MediaItem{}, {:manual, false}), do: %{prevent_download: false}
end
