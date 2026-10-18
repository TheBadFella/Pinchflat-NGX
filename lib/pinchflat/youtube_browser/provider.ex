defmodule Pinchflat.YoutubeBrowser.Provider do
  @moduledoc """
  Behaviour definition for YouTube browsing extraction providers.
  """

  @type video_result :: %{
          id: String.t(),
          url: String.t(),
          title: String.t(),
          channel_id: String.t() | nil,
          channel_title: String.t() | nil,
          duration: integer() | nil,
          upload_date: String.t() | nil,
          thumbnail: String.t() | nil,
          view_count: integer() | nil
        }

  @type channel_result :: %{
          id: String.t(),
          url: String.t(),
          title: String.t(),
          handle: String.t() | nil,
          thumbnail: String.t() | nil,
          subscriber_count: integer() | nil
        }

  @type video_detail :: %{
          id: String.t(),
          url: String.t(),
          title: String.t(),
          description: String.t() | nil,
          channel_id: String.t() | nil,
          channel_title: String.t() | nil,
          duration: integer() | nil,
          upload_date: String.t() | nil,
          thumbnails: list(map()),
          thumbnail: String.t() | nil,
          view_count: integer() | nil
        }

  @callback search_videos(query :: String.t(), opts :: keyword()) ::
              {:ok, list(video_result())} | {:error, any()}

  @callback search_channels(query :: String.t(), opts :: keyword()) ::
              {:ok, list(channel_result())} | {:error, any()}

  @callback get_video_details(video_id :: String.t(), opts :: keyword()) ::
              {:ok, video_detail()} | {:error, any()}

  @callback get_channel_preview(channel_id_or_url :: String.t(), opts :: keyword()) ::
              {:ok, list(video_result())} | {:error, any()}
end
