defmodule Pinchflat.SettingsTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.Settings.Setting

  # NOTE: We're treating some of these tests differently
  # than in other modules because certain settings
  # are always created on app boot (including in the test env),
  # so we can't treat these like a clean slate.

  setup do
    # Ensure we have a clean slate
    Settings.set(onboarding: false)
    Settings.set(pro_enabled: false)
    Settings.set(yt_dlp_version: nil)
    Settings.set(external_base_url: nil)

    :ok
  end

  describe "record/0" do
    test "returns the only setting" do
      assert %Setting{} = Settings.record()
    end
  end

  describe "update_setting/2" do
    test "does not log notification credentials or API keys when saving settings" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)

      try do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            assert {:ok, _} =
                     Settings.update_setting(Settings.record(), %{
                       apprise_server: "json://lab:SECRET_SETTINGS187@example.invalid/hook",
                       youtube_api_key: "SECRET_SETTINGS187"
                     })

            assert Settings.get!(:apprise_server) =~ "SECRET_SETTINGS187"
            assert Settings.get!(:youtube_api_key) == "SECRET_SETTINGS187"
            Repo.query!("SELECT 1")
          end)

        assert log =~ "SELECT 1"
        refute log =~ "SECRET_SETTINGS187"
      after
        Logger.configure(level: previous_level)
      end
    end

    test "updates the setting" do
      setting = Settings.record()

      assert {:ok, false} = Settings.get(:onboarding)
      assert {:ok, %Setting{}} = Settings.update_setting(setting, %{onboarding: true})
      assert {:ok, true} = Settings.get(:onboarding)
    end
  end

  describe "set/1" do
    test "updates the setting" do
      assert {:ok, true} = Settings.set(onboarding: true)
      assert {:ok, true} = Settings.get(:onboarding)
    end

    test "updates the external base url" do
      assert {:ok, "https://pinchflat.example.com"} = Settings.set(external_base_url: "https://pinchflat.example.com")
      assert {:ok, "https://pinchflat.example.com"} = Settings.get(:external_base_url)
    end

    test "returns an error if the setting key doesn't exist" do
      assert {:error, :invalid_key} = Settings.set(foo: "bar")
    end

    test "returns an error if the setting value is invalid" do
      assert {:error, %Ecto.Changeset{}} = Settings.set(onboarding: "bar")
    end
  end

  describe "get/1" do
    test "returns the setting value" do
      assert {:ok, false} = Settings.get(:onboarding)
    end

    test "returns an error if the setting key doesn't exist" do
      assert {:error, :invalid_key} = Settings.get(:foo)
    end
  end

  describe "get!/1" do
    test "returns the setting value" do
      assert Settings.get!(:onboarding) == false
    end

    test "raises an error if the setting key doesn't exist" do
      assert_raise RuntimeError, "Setting `foo` not found", fn ->
        Settings.get!(:foo)
      end
    end
  end

  describe "change_setting/2" do
    test "returns a changeset" do
      setting = Settings.record()

      assert %Ecto.Changeset{} = Settings.change_setting(setting, %{onboarding: true})
    end

    test "ensures the extractor sleep interval is positive" do
      setting = Settings.record()

      assert %Ecto.Changeset{valid?: true} = Settings.change_setting(setting, %{extractor_sleep_interval_seconds: 1})
      assert %Ecto.Changeset{valid?: true} = Settings.change_setting(setting, %{extractor_sleep_interval_seconds: 0})
      assert %Ecto.Changeset{valid?: false} = Settings.change_setting(setting, %{extractor_sleep_interval_seconds: -1})
    end

    test "allows you to reset the extractor sleep interval" do
      setting = Settings.record()
      assert {:ok, setting} = Settings.update_setting(setting, %{extractor_sleep_interval_seconds: 1})

      assert %Ecto.Changeset{valid?: true} = Settings.change_setting(setting, %{extractor_sleep_interval_seconds: 0})
    end

    test "only allows known yt-dlp update policies" do
      setting = Settings.record()

      assert %Ecto.Changeset{valid?: true} = Settings.change_setting(setting, %{yt_dlp_update_policy: "nightly"})
      assert %Ecto.Changeset{valid?: false} = Settings.change_setting(setting, %{yt_dlp_update_policy: "bogus"})
    end

    test "requires worker concurrency to be between 1 and 20" do
      setting = Settings.record()

      assert %Ecto.Changeset{valid?: true} =
               Settings.change_setting(setting, %{yt_dlp_download_worker_concurrency: 2})

      assert %Ecto.Changeset{valid?: false} =
               Settings.change_setting(setting, %{yt_dlp_download_worker_concurrency: 0})

      assert %Ecto.Changeset{valid?: false} =
               Settings.change_setting(setting, %{yt_dlp_download_worker_concurrency: 21})
    end

    test "requires PostgreSQL backup retention to be between 1 and 100" do
      setting = Settings.record()

      assert %Ecto.Changeset{valid?: true} =
               Settings.change_setting(setting, %{postgres_backup_retention_count: 1})

      assert %Ecto.Changeset{valid?: true} =
               Settings.change_setting(setting, %{postgres_backup_retention_count: 100})

      assert %Ecto.Changeset{valid?: false} =
               Settings.change_setting(setting, %{postgres_backup_retention_count: 0})

      assert %Ecto.Changeset{valid?: false} =
               Settings.change_setting(setting, %{postgres_backup_retention_count: 101})
    end

    test "requires a pinned version when the policy is pinned" do
      setting = Settings.record()

      assert %Ecto.Changeset{valid?: false} = Settings.change_setting(setting, %{yt_dlp_update_policy: "pinned"})

      assert %Ecto.Changeset{valid?: true} =
               Settings.change_setting(setting, %{yt_dlp_update_policy: "pinned", yt_dlp_pinned_version: "2025.12.08"})
    end
  end

  describe "codec preference validation" do
    setup do
      on_exit(fn ->
        Settings.update_setting(Settings.record(), %{
          video_codec_preference: "avc",
          audio_codec_preference: "m4a"
        })
      end)

      {:ok, setting: Settings.record()}
    end

    test "accepts a single legacy codec", %{setting: setting} do
      assert %Ecto.Changeset{valid?: true} = Settings.change_setting(setting, %{video_codec_preference: "avc"})
      assert %Ecto.Changeset{valid?: true} = Settings.change_setting(setting, %{audio_codec_preference: "m4a"})
    end

    test "accepts an ordered list and canonicalizes it", %{setting: setting} do
      changeset = Settings.change_setting(setting, %{video_codec_preference: " AV1 , vp9 ,avc "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :video_codec_preference) == "av1,vp9,avc"
    end

    test "canonicalizes aliases to canonical select values on save", %{setting: setting} do
      video_changeset = Settings.change_setting(setting, %{video_codec_preference: "H264,VP09"})
      assert video_changeset.valid?
      assert Ecto.Changeset.get_change(video_changeset, :video_codec_preference) == "avc,vp9"

      # Default setting has audio_codec_preference == "m4a", so start with a different value to observe change
      audio_setting = %{setting | audio_codec_preference: "opus"}
      audio_changeset = Settings.change_setting(audio_setting, %{audio_codec_preference: "aac"})
      assert audio_changeset.valid?
      assert Ecto.Changeset.get_change(audio_changeset, :audio_codec_preference) == "m4a"

      wav_changeset = Settings.change_setting(audio_setting, %{audio_codec_preference: "aiff,opus"})
      assert wav_changeset.valid?
      assert Ecto.Changeset.get_change(wav_changeset, :audio_codec_preference) == "wav,opus"
    end

    test "round-trips wav and aiff aliases through save and reload", %{setting: setting} do
      assert {:ok, saved} = Settings.update_setting(setting, %{audio_codec_preference: "aiff,opus"})
      assert saved.audio_codec_preference == "wav,opus"

      reloaded = Pinchflat.Repo.reload!(saved)
      assert reloaded.audio_codec_preference == "wav,opus"

      # Subsequent save with the stored canonical value succeeds and remains valid
      changeset = Settings.change_setting(reloaded, %{audio_codec_preference: reloaded.audio_codec_preference})
      assert changeset.valid?
    end

    test "an unrelated settings save does not rewrite an already-stored legacy value unexpectedly", %{setting: setting} do
      # Directly set legacy codec values in the database without going through canonicalization
      legacy_attrs = %{video_codec_preference: "h264", audio_codec_preference: "mp4a"}
      {:ok, legacy_setting} = Pinchflat.Repo.update(Ecto.Changeset.change(setting, legacy_attrs))
      assert legacy_setting.video_codec_preference == "h264"
      assert legacy_setting.audio_codec_preference == "mp4a"

      # Perform an unrelated save (only updating extractor_sleep_interval_seconds)
      assert {:ok, updated} = Settings.update_setting(legacy_setting, %{extractor_sleep_interval_seconds: 10})

      # The legacy values are preserved untouched because normalize_codec_preferences detects
      # the fields were omitted from the update attrs and returns :unchanged
      assert updated.video_codec_preference == "h264"
      assert updated.audio_codec_preference == "mp4a"
      assert updated.extractor_sleep_interval_seconds == 10
    end

    test "round-trips an empty string as an empty string", %{setting: setting} do
      changeset = Settings.change_setting(setting, %{video_codec_preference: "", audio_codec_preference: ""})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :video_codec_preference) == ""
      assert Ecto.Changeset.get_change(changeset, :audio_codec_preference) == ""
    end

    test "persists a cleared list without violating NOT NULL", %{setting: setting} do
      assert {:ok, saved} = Settings.update_setting(setting, %{video_codec_preference: "avc"})
      assert {:ok, saved} = Settings.update_setting(saved, %{video_codec_preference: ""})

      assert saved.video_codec_preference == ""
    end

    test "rejects an unknown codec", %{setting: setting} do
      changeset = Settings.change_setting(setting, %{video_codec_preference: "boguscodec"})

      refute changeset.valid?
      assert {msg, _} = changeset.errors[:video_codec_preference]
      assert msg =~ "unsupported codec" and msg =~ "boguscodec"
    end

    test "rejects an unknown audio codec", %{setting: setting} do
      changeset = Settings.change_setting(setting, %{audio_codec_preference: "fakeaudio"})

      refute changeset.valid?
      assert {msg, _} = changeset.errors[:audio_codec_preference]
      assert msg =~ "unsupported codec" and msg =~ "fakeaudio"
    end

    test "rejects duplicate equivalent video codecs", %{setting: setting} do
      changeset = Settings.change_setting(setting, %{video_codec_preference: "vp9,vp09"})

      refute changeset.valid?

      assert {"lists the same codec twice (vp9, vp09); keep only one entry", _} =
               changeset.errors[:video_codec_preference]
    end

    test "rejects duplicate equivalent audio codecs", %{setting: setting} do
      changeset = Settings.change_setting(setting, %{audio_codec_preference: "aac,m4a"})

      refute changeset.valid?

      assert {"lists the same codec twice (aac, m4a); keep only one entry", _} =
               changeset.errors[:audio_codec_preference]
    end

    test "rejects more than eight codecs", %{setting: setting} do
      changeset =
        Settings.change_setting(setting, %{
          video_codec_preference: "avc,vp9,av1,hevc,mpeg4,theora,wmv3,flv1,vp8"
        })

      refute changeset.valid?
      assert {"must contain at most 8 codecs", _} = changeset.errors[:video_codec_preference]
    end

    test "rejects a list longer than 256 bytes", %{setting: setting} do
      value = String.duplicate("avc,", 70) <> "avc"
      changeset = Settings.change_setting(setting, %{video_codec_preference: value})

      refute changeset.valid?
      assert {"must be at most 256 bytes; shorten the list", _} = changeset.errors[:video_codec_preference]
    end
  end
end
