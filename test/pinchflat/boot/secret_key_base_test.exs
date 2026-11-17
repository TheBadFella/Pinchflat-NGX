defmodule Pinchflat.Boot.SecretKeyBaseTest do
  use ExUnit.Case, async: true

  alias Pinchflat.Boot.SecretKeyBase

  @moduletag :tmp_dir

  test "uses an explicit SECRET_KEY_BASE without touching the config directory", %{tmp_dir: dir} do
    assert SecretKeyBase.resolve("explicit-key", "selfhosted", dir) == "explicit-key"
    refute File.exists?(Path.join(dir, ".secret_key_base"))
  end

  test "generates, stores and reuses a per-install key when unset", %{tmp_dir: dir} do
    key = SecretKeyBase.resolve(nil, "selfhosted", dir)
    path = Path.join(dir, ".secret_key_base")

    assert byte_size(key) >= 64
    assert File.read!(path) == key
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert SecretKeyBase.resolve("", "selfhosted", dir) == key

    other_dir = Path.join(dir, "other")
    refute SecretKeyBase.resolve(nil, "selfhosted", other_dir) == key
  end

  test "replaces a stored key that is too short", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".secret_key_base"), "short\n")

    key = SecretKeyBase.resolve(nil, "selfhosted", dir)

    assert byte_size(key) >= 64
    refute key == "short"
  end

  test "requires SECRET_KEY_BASE outside the self-hosted image", %{tmp_dir: dir} do
    assert_raise RuntimeError, ~r/SECRET_KEY_BASE is missing/, fn ->
      SecretKeyBase.resolve(nil, nil, dir)
    end
  end

  test "fails clearly when the config path is not writable", %{tmp_dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, "not a directory")

    assert_raise RuntimeError, ~r/Make the config directory writable or set SECRET_KEY_BASE/, fn ->
      SecretKeyBase.resolve(nil, "selfhosted", path)
    end
  end
end
