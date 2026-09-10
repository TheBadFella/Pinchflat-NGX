defmodule Pinchflat.Sources.AvailabilityPolicyTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources.AvailabilityPolicy

  describe "evaluate/2" do
    for {availability, field, reason} <- [
          {:public, :download_public_media, :public_media_disabled},
          {:unlisted, :download_public_media, :public_media_disabled},
          {:subscriber_only, :download_members_only_media, :members_only_media_disabled},
          {:premium_only, :download_members_only_media, :members_only_media_disabled},
          {:needs_auth, :download_members_only_media, :members_only_media_disabled}
        ] do
      test "blocks #{availability} when #{field} is disabled" do
        source = source_fixture(%{unquote(field) => false})

        assert {:block, unquote(reason)} = AvailabilityPolicy.evaluate(source, unquote(availability))
      end
    end

    test "private media is always blocked" do
      source = source_fixture(%{download_public_media: true, download_members_only_media: true})

      assert {:block, :private_media} = AvailabilityPolicy.evaluate(source, :private)
    end

    test "allows all known values when their policy is enabled" do
      source = source_fixture()

      for availability <- AvailabilityPolicy.known_values() -- [:private] do
        assert AvailabilityPolicy.evaluate(source, availability) == :allow
      end
    end

    test "allows missing and unknown values" do
      source = source_fixture(%{download_public_media: false, download_members_only_media: false})

      assert AvailabilityPolicy.evaluate(source, nil) == :allow
      assert AvailabilityPolicy.evaluate(source, "future_visibility") == :allow
    end
  end
end
