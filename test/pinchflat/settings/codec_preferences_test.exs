defmodule Pinchflat.Settings.CodecPreferencesTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Settings.CodecPreferences

  describe "parse/1" do
    test "returns an empty list for blank and nil input" do
      assert CodecPreferences.parse(nil) == []
      assert CodecPreferences.parse("") == []
      assert CodecPreferences.parse("  ") == []
      assert CodecPreferences.parse(" , ") == []
    end

    test "splits, trims and lowercases tokens while preserving order" do
      assert CodecPreferences.parse(" VP9, AVC ,av1 ") == ["vp9", "avc", "av1"]
    end

    test "preserves a single token" do
      assert CodecPreferences.parse("avc") == ["avc"]
    end
  end

  describe "format/1" do
    test "canonicalizes a token list" do
      assert CodecPreferences.format([" VP9 ", "AVC"]) == "vp9,avc"
    end

    test "formats empty values as an empty string" do
      assert CodecPreferences.format([]) == ""
      assert CodecPreferences.format(nil) == ""
    end

    test "round-trips a parsed value" do
      assert "vp9,avc,av1" |> CodecPreferences.parse() |> CodecPreferences.format() == "vp9,avc,av1"
    end
  end

  describe "validate/2" do
    test "accepts blank, single and ordered supported lists" do
      assert :ok = CodecPreferences.validate(:video, "")
      assert :ok = CodecPreferences.validate(:video, "avc")
      assert :ok = CodecPreferences.validate(:video, "vp9,avc,av1")
      assert :ok = CodecPreferences.validate(:audio, "opus,m4a,flac")
    end

    test "accepts documented aliases as distinct entries" do
      assert :ok = CodecPreferences.validate(:video, "avc,vp9,av1")
      assert :ok = CodecPreferences.validate(:audio, "m4a,opus,flac,mp3,wav")
    end

    test "rejects an unsupported codec" do
      assert {:error, message} = CodecPreferences.validate(:video, "boguscodec")
      assert message =~ "unsupported codec"
      assert message =~ "boguscodec"
    end

    test "rejects an unsupported audio codec" do
      assert {:error, message} = CodecPreferences.validate(:audio, "fakeaudio")
      assert message =~ "unsupported codec"
    end
  end

  describe "validate/2 duplicates and bounds" do
    test "rejects duplicate equivalent aliases" do
      assert {:error, vp9_message} = CodecPreferences.validate(:video, "vp9,vp09")
      assert vp9_message =~ "same codec twice"

      assert {:error, av1_message} = CodecPreferences.validate(:video, "av1,av01")
      assert av1_message =~ "same codec twice"
    end

    test "rejects the aac/m4a family collision" do
      assert {:error, message} = CodecPreferences.validate(:audio, "aac,m4a")
      assert message =~ "same codec twice"
    end

    test "rejects the wav/aiff family collision" do
      assert {:error, message} = CodecPreferences.validate(:audio, "wav,aiff")
      assert message =~ "same codec twice"
    end

    test "rejects more than the maximum number of codecs" do
      assert {:error, message} =
               CodecPreferences.validate(:video, "avc,vp9,av1,hevc,vp8,mp4v,theora,foo,bar,baz")

      assert message =~ "at most"
    end

    test "rejects an oversized serialized list" do
      oversized = Enum.map_join(1..80, ",", fn _ -> "avc" end)
      assert byte_size(oversized) > CodecPreferences.max_bytes()
      assert {:error, message} = CodecPreferences.validate(:video, oversized)
      assert message =~ "bytes"
    end
  end

  describe "family/2" do
    test "maps aliases to the same family" do
      assert CodecPreferences.family(:video, "avc") == CodecPreferences.family(:video, "avc1")
      assert CodecPreferences.family(:video, "vp9") == CodecPreferences.family(:video, "vp09")
      assert CodecPreferences.family(:video, "av1") == CodecPreferences.family(:video, "av01")
      assert CodecPreferences.family(:audio, "m4a") == CodecPreferences.family(:audio, "mp4a")
      assert CodecPreferences.family(:audio, "wav") == :wav
      assert CodecPreferences.family(:audio, "aiff") == :wav
      assert CodecPreferences.family(:audio, "pcm") == :wav
    end

    test "returns nil for unknown codecs" do
      assert CodecPreferences.family(:video, "nope") == nil
      assert CodecPreferences.family(:audio, "nope") == nil
    end
  end

  describe "canonical_token/2 and canonical_tokens/2" do
    test "canonicalizes known aliases to select values" do
      assert CodecPreferences.canonical_token(:video, "H264") == "avc"
      assert CodecPreferences.canonical_token(:video, "VP09") == "vp9"
      assert CodecPreferences.canonical_token(:video, "av01") == "av1"
      assert CodecPreferences.canonical_token(:audio, "aac") == "m4a"
      assert CodecPreferences.canonical_token(:audio, "mp4a") == "m4a"
      assert CodecPreferences.canonical_token(:audio, "wav") == "wav"
      assert CodecPreferences.canonical_token(:audio, "aiff") == "wav"
      assert CodecPreferences.canonical_token(:audio, "pcm") == "wav"
    end

    test "preserves unknown tokens for validation" do
      assert CodecPreferences.canonical_token(:video, "bogus") == "bogus"
      assert CodecPreferences.canonical_token(:audio, "unknown") == "unknown"
    end

    test "canonicalizes token lists" do
      assert CodecPreferences.canonical_tokens(:video, ["H264", "VP09"]) == ["avc", "vp9"]
      assert CodecPreferences.canonical_tokens(:audio, ["aac", "opus"]) == ["m4a", "opus"]
    end
  end

  describe "shape helpers" do
    test "classifies single, ordered and empty values" do
      assert CodecPreferences.single_entry?("avc")
      refute CodecPreferences.single_entry?("avc,vp9")
      refute CodecPreferences.single_entry?("")

      assert CodecPreferences.ordered?("avc,vp9")
      refute CodecPreferences.ordered?("avc")
      refute CodecPreferences.ordered?("")

      assert CodecPreferences.single_token("avc,vp9") == "avc"
      assert CodecPreferences.single_token("") == nil
    end

    test "requires the plugin only when a list is ordered" do
      refute CodecPreferences.plugin_required?("avc", "m4a")
      refute CodecPreferences.plugin_required?("", "")
      assert CodecPreferences.plugin_required?("vp9,avc", "m4a")
      assert CodecPreferences.plugin_required?("avc", "opus,m4a")
    end
  end
end
