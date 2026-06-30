defmodule Pinchflat.Utils.VersionUtilsTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Utils.VersionUtils

  describe "compare/2" do
    test "compares by date components" do
      assert VersionUtils.compare("2025.07.01", "2025.06.28") == :gt
      assert VersionUtils.compare("2025.06.28", "2025.07.01") == :lt
      assert VersionUtils.compare("2025.07.01", "2025.07.01") == :eq
    end

    test "treats a same-day nightly as newer than that day's stable" do
      assert VersionUtils.compare("2025.06.28.123456", "2025.06.28") == :gt
      assert VersionUtils.compare("2025.06.28", "2025.06.28.123456") == :lt
    end

    test "treats missing trailing components as zero" do
      assert VersionUtils.compare("2025.07.01", "2025.07.01.0") == :eq
    end

    test "a later stable date beats an earlier nightly even with a trailing component" do
      assert VersionUtils.compare("2025.07.01", "2025.06.28.999999") == :gt
    end

    test "handles whitespace and non-numeric junk gracefully" do
      assert VersionUtils.compare(" 2025.07.01 ", "2025.07.01") == :eq
    end
  end
end
