defmodule Pinchflat.Media.DownloadStateTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Media.DownloadState
  alias Pinchflat.Media.MediaItem

  test "classifies a transient failure without preventing the next attempt" do
    media_item = media_item()

    assert DownloadState.transition(media_item, {:failure, :transient, false}) == %{error_type: :transient}

    transient_item = %{media_item | error_type: :transient, last_error: "Network is unreachable"}
    assert DownloadState.transition(transient_item, :success) == %{error_type: nil, last_error: nil}
  end

  test "classifies a permanent failure and prevents future automatic attempts" do
    media_item = media_item()

    assert DownloadState.transition(media_item, {:failure, :permanent, false}) == %{
             error_type: :permanent,
             prevent_download: true,
             download_prevented_reason: :error
           }
  end

  test "a failed forced retry keeps an existing permanent block" do
    media_item = media_item(error_type: :permanent, prevent_download: true, download_prevented_reason: :error)

    assert DownloadState.transition(media_item, {:failure, :transient, true}) == %{error_type: :permanent}
  end

  test "a successful retry clears a permanent error block and diagnostic" do
    media_item =
      media_item(
        error_type: :permanent,
        last_error: "Video unavailable",
        prevent_download: true,
        download_prevented_reason: :error
      )

    assert DownloadState.transition(media_item, :success) == %{
             error_type: nil,
             last_error: nil,
             prevent_download: false,
             download_prevented_reason: nil
           }
  end

  test "policy transitions preserve manual and error prevention" do
    manual_item = media_item(prevent_download: true, download_prevented_reason: :manual)
    error_item = media_item(prevent_download: true, download_prevented_reason: :error, error_type: :permanent)
    policy_item = media_item(prevent_download: true, download_prevented_reason: :policy)
    policy_block = media_item()

    assert DownloadState.transition(manual_item, :policy_allowed) == %{}
    assert DownloadState.transition(error_item, :policy_allowed) == %{}
    assert DownloadState.transition(manual_item, :policy_block) == %{}

    assert DownloadState.transition(policy_item, {:manual, true}) == %{
             error_type: nil,
             last_error: nil,
             prevent_download: true,
             download_prevented_reason: :manual
           }

    assert DownloadState.transition(policy_item, :policy_allowed) == %{
             prevent_download: false,
             download_prevented_reason: nil
           }

    assert DownloadState.transition(policy_block, :policy_block) == %{
             prevent_download: true,
             download_prevented_reason: :policy
           }

    blocked_item = %{policy_block | prevent_download: true, download_prevented_reason: :policy}

    assert DownloadState.transition(blocked_item, :policy_allowed) == %{
             prevent_download: false,
             download_prevented_reason: nil
           }
  end

  test "manual prevention can be set and cleared" do
    media_item = media_item()

    assert DownloadState.transition(media_item, {:manual, true}) == %{
             error_type: nil,
             last_error: nil,
             prevent_download: true,
             download_prevented_reason: :manual
           }

    manual_item = %{media_item | prevent_download: true, download_prevented_reason: :manual}

    assert DownloadState.transition(manual_item, {:manual, false}) == %{
             error_type: nil,
             last_error: nil,
             prevent_download: false,
             download_prevented_reason: nil
           }
  end

  defp media_item(attrs \\ []) do
    struct!(MediaItem, Keyword.merge([availability: :public, prevent_download: false], attrs))
  end
end
