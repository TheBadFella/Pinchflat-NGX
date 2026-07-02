defmodule Pinchflat.Settings.CookieFileTest do
  use ExUnit.Case, async: false

  alias Pinchflat.Settings.CookieFile

  setup do
    base_dir =
      Path.join([System.tmp_dir!(), "cookie_file_test", Integer.to_string(:erlang.unique_integer([:positive]))])

    File.mkdir_p!(base_dir)
    original = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir}
  end

  defp write_cookies(contents), do: File.write!(CookieFile.filepath(), contents)

  describe "filepath/0" do
    test "points at cookies.txt in the extras directory", %{base_dir: base_dir} do
      assert CookieFile.filepath() == Path.join(base_dir, "cookies.txt")
    end
  end

  describe "present?/0" do
    test "is false when the file is missing" do
      refute CookieFile.present?()
    end

    test "is false when the file is blank" do
      write_cookies("   \n  ")
      refute CookieFile.present?()
    end

    test "is true when the file has contents" do
      write_cookies(".youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue")
      assert CookieFile.present?()
    end
  end

  describe "save_from_path/1 and clear/0" do
    test "save_from_path copies the source file into place" do
      source = Path.join(System.tmp_dir!(), "uploaded_cookies_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(source, "some-cookie-contents")

      assert :ok = CookieFile.save_from_path(source)
      assert {:ok, "some-cookie-contents"} = CookieFile.read()

      File.rm!(source)
    end

    test "clear blanks the file but keeps it present on disk" do
      write_cookies("stuff")
      assert :ok = CookieFile.clear()
      refute CookieFile.present?()
      assert File.exists?(CookieFile.filepath())
    end
  end

  describe "validate/0" do
    test "returns :empty for a blank file" do
      write_cookies("")
      assert {:error, :empty} = CookieFile.validate()
    end

    test "returns :empty when the file does not exist" do
      assert {:error, :empty} = CookieFile.validate()
    end

    test "returns :invalid when no cookie lines can be parsed" do
      write_cookies("just some junk\nno tabs here either")
      assert {:error, :invalid} = CookieFile.validate()
    end

    test "ignores comment lines but keeps #HttpOnly_ cookies" do
      write_cookies("""
      # Netscape HTTP Cookie File
      #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue
      """)

      assert {:ok, %{total: 1, active: 1, expired: 0}} = CookieFile.validate(1_700_000_000)
    end

    test "counts active and expired cookies relative to now" do
      write_cookies("""
      .youtube.com\tTRUE\t/\tTRUE\t9999999999\tACTIVE\tvalue
      .youtube.com\tTRUE\t/\tTRUE\t1000000000\tEXPIRED\tvalue
      """)

      assert {:ok, %{total: 2, active: 1, expired: 1}} = CookieFile.validate(1_700_000_000)
    end

    test "treats session cookies (expiry 0) as active" do
      write_cookies(".youtube.com\tTRUE\t/\tTRUE\t0\tSESSION\tvalue")

      assert {:ok, %{total: 1, active: 1, expired: 0}} = CookieFile.validate(1_700_000_000)
    end
  end
end
