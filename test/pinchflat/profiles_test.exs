defmodule Pinchflat.ProfilesTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles
  alias Pinchflat.Profiles.MediaProfile

  @invalid_attrs %{name: nil, output_path_template: nil}

  describe "schema" do
    test "can be JSON encoded without error" do
      profile = media_profile_fixture()

      assert {:ok, _} = Phoenix.json_library().encode(profile)
    end

    test "does not ignore YouTube Super Resolution by default" do
      profile = media_profile_fixture()

      refute profile.ignore_youtube_super_resolution
    end
  end

  describe "list_media_profiles/0" do
    test "it returns all media_profiles" do
      media_profile = media_profile_fixture()
      assert Profiles.list_media_profiles() == [media_profile]
    end
  end

  describe "get_media_profile!/1" do
    test "it returns the media_profile with given id" do
      media_profile = media_profile_fixture()
      assert Profiles.get_media_profile!(media_profile.id) == media_profile
    end
  end

  describe "create_media_profile/1" do
    test "creation with valid data creates a media_profile" do
      valid_attrs = %{name: "some name", output_path_template: "output_template.{{ ext }}"}

      assert {:ok, %MediaProfile{} = media_profile} = Profiles.create_media_profile(valid_attrs)
      assert media_profile.name == "some name"
      assert media_profile.output_path_template == "output_template.{{ ext }}"
    end

    test "creation with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Profiles.create_media_profile(@invalid_attrs)
    end
  end

  describe "create_media_profile/1 when testing sponsorblock categories" do
    test "different categories can be marked and removed at the same time" do
      attrs = %{
        name: "sponsorblock test",
        output_path_template: "output.{{ ext }}",
        sponsorblock_remove_categories: ["sponsor", "selfpromo", "hook"],
        sponsorblock_mark_categories: ["intro", "outro"]
      }

      assert {:ok, %MediaProfile{} = media_profile} = Profiles.create_media_profile(attrs)
      assert media_profile.sponsorblock_remove_categories == ["sponsor", "selfpromo", "hook"]
      assert media_profile.sponsorblock_mark_categories == ["intro", "outro"]
    end

    test "a category can't be both marked and removed" do
      attrs = %{
        name: "sponsorblock test",
        output_path_template: "output.{{ ext }}",
        sponsorblock_remove_categories: ["sponsor", "intro"],
        sponsorblock_mark_categories: ["intro"]
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Profiles.create_media_profile(attrs)
      assert "can't mark and remove the same category: intro" in errors_on(changeset).sponsorblock_mark_categories
    end

    test "unknown categories are rejected" do
      attrs = %{
        name: "sponsorblock test",
        output_path_template: "output.{{ ext }}",
        sponsorblock_remove_categories: ["sponsor", "not_a_category"]
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Profiles.create_media_profile(attrs)
      assert errors_on(changeset).sponsorblock_remove_categories != []
    end

    test "empty-string entries from the form's hidden input are discarded" do
      attrs = %{
        name: "sponsorblock test",
        output_path_template: "output.{{ ext }}",
        sponsorblock_remove_categories: [""],
        sponsorblock_mark_categories: ["", "intro"]
      }

      assert {:ok, %MediaProfile{} = media_profile} = Profiles.create_media_profile(attrs)
      assert media_profile.sponsorblock_remove_categories == []
      assert media_profile.sponsorblock_mark_categories == ["intro"]
    end

    test "unchecking every category clears a previously-set list" do
      media_profile = media_profile_fixture(%{sponsorblock_remove_categories: ["sponsor", "intro"]})

      # A fully-unchecked checkbox group submits only the hidden input's empty string
      assert {:ok, %MediaProfile{} = media_profile} =
               Profiles.update_media_profile(media_profile, %{"sponsorblock_remove_categories" => [""]})

      assert media_profile.sponsorblock_remove_categories == []
      assert Profiles.get_media_profile!(media_profile.id).sponsorblock_remove_categories == []
    end
  end

  describe "update_media_profile/2" do
    test "updating with valid data updates the media_profile" do
      media_profile = media_profile_fixture()

      update_attrs = %{
        name: "some updated name",
        output_path_template: "new_output_template.{{ ext }}"
      }

      assert {:ok, %MediaProfile{} = media_profile} =
               Profiles.update_media_profile(media_profile, update_attrs)

      assert media_profile.name == "some updated name"
      assert media_profile.output_path_template == "new_output_template.{{ ext }}"
    end

    test "updates the YouTube Super Resolution preference" do
      media_profile = media_profile_fixture()

      assert {:ok, %MediaProfile{} = media_profile} =
               Profiles.update_media_profile(media_profile, %{ignore_youtube_super_resolution: true})

      assert media_profile.ignore_youtube_super_resolution
      assert Profiles.get_media_profile!(media_profile.id).ignore_youtube_super_resolution
    end

    test "updating with invalid data returns error changeset" do
      media_profile = media_profile_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Profiles.update_media_profile(media_profile, @invalid_attrs)

      assert media_profile == Profiles.get_media_profile!(media_profile.id)
    end
  end

  describe "delete_media_profile/2" do
    test "deletion deletes the media_profile" do
      media_profile = media_profile_fixture()

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_profile) end
    end

    test "deletion deletes all sources" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
    end

    test "deletion deletes all media items" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_fixture(source_id: source.id)

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
    end

    test "deletion does not delete files by default" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile)

      assert File.exists?(media_item.media_filepath)
    end
  end

  describe "delete_media_profile/2 when deleting files" do
    setup do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      :ok
    end

    test "still deletes all the needful records" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_fixture(source_id: source.id)

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile, delete_files: true)

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_profile) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
    end

    test "deletes files" do
      media_profile = media_profile_fixture()
      source = source_fixture(media_profile_id: media_profile.id)
      media_item = media_item_with_attachments(%{source_id: source.id})

      assert {:ok, %MediaProfile{}} = Profiles.delete_media_profile(media_profile, delete_files: true)

      refute File.exists?(media_item.media_filepath)
    end
  end

  describe "change_media_profile/1" do
    test "it returns a media_profile changeset" do
      media_profile = media_profile_fixture()
      assert %Ecto.Changeset{} = Profiles.change_media_profile(media_profile)
    end

    test "it ensures the media profile's output template ends with an extension" do
      valid_templates = [
        "output_template.{{ ext }}",
        "output_template.{{ext}}",
        "output_template.%(ext)s",
        "output_template.%(ext)S",
        "output_template.%( ext )s",
        "output_template.%( ext )S"
      ]

      for template <- valid_templates do
        cs = Profiles.change_media_profile(%MediaProfile{}, %{name: "a", output_path_template: template})

        assert cs.valid?
      end
    end

    test "it does not allow invalid output templates" do
      invalid_templates = [
        "output_template.{{ ext }}.something",
        "output_template.{{   ext   }}",
        "output_template{{ ext }}",
        "output_template.%(ext)s.something",
        "output_template.txt",
        "output_template%(ext)s",
        "output_template.%(nope)s",
        "output_template"
      ]

      for template <- invalid_templates do
        cs = Profiles.change_media_profile(%MediaProfile{}, %{name: "a", output_path_template: template})

        refute cs.valid?
      end
    end
  end
end
