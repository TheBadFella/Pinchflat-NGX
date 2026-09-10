defmodule Pinchflat.Sources.AvailabilityPolicy do
  @moduledoc """
  Decides whether a source's availability policy allows a media item to download.

  Unknown and missing availability remains eligible so that adding this policy
  does not change the behavior of media whose backend metadata is incomplete.
  """

  import Ecto.Query

  alias Pinchflat.Sources.Source

  @public_values [:public, :unlisted]
  @members_only_values [:subscriber_only, :premium_only, :needs_auth]
  @known_values @public_values ++ @members_only_values ++ [:private]

  @doc """
  Returns `:allow` or `{:block, reason}` for a source and availability value.

  Unknown values are allowed and never converted into atoms.
  """
  def evaluate(%Source{} = source, availability) do
    case availability do
      availability when availability in @public_values ->
        if source.download_public_media != false, do: :allow, else: {:block, :public_media_disabled}

      availability when availability in @members_only_values ->
        if source.download_members_only_media != false,
          do: :allow,
          else: {:block, :members_only_media_disabled}

      :private ->
        {:block, :private_media}

      value when is_binary(value) ->
        evaluate(source, normalize(value))

      _unknown_or_missing ->
        :allow
    end
  end

  @doc "Returns whether the source policy allows the media item to download."
  def allowed?(%Source{} = source, availability), do: evaluate(source, availability) == :allow

  @doc "Returns the known availability values used by the policy matrix."
  def known_values, do: @known_values

  @doc """
  Returns the SQL predicate matching `evaluate/2` for a query joined as
  `[media_item, source]`.
  """
  def query_condition do
    dynamic(
      [media_item, source],
      is_nil(media_item.availability) or
        media_item.availability not in ^@known_values or
        (media_item.availability in ^@public_values and source.download_public_media == true) or
        (media_item.availability in ^@members_only_values and source.download_members_only_media == true)
    )
  end

  defp normalize(value) do
    case value do
      "public" -> :public
      "unlisted" -> :unlisted
      "subscriber_only" -> :subscriber_only
      "premium_only" -> :premium_only
      "needs_auth" -> :needs_auth
      "private" -> :private
      _unknown -> nil
    end
  end
end
