defmodule Pinchflat.Tooling.VersionBumpTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../tooling/version_bump.sh", __DIR__)

  setup do
    directory = Path.join(System.tmp_dir!(), "version-bump-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "mix.exs"), ~s(version: "2026.10.20"))
    File.write!(Path.join(directory, "mix"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(directory, "mix"), 0o755)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "requires an explicit valid year.month.patch without changing the file", %{directory: directory} do
    for args <- [[], ["2026.13.0"], ["2026.11"], ["2026.11.0", "extra"]] do
      assert {_output, 1} = run_script(directory, args)
      assert File.read!(Path.join(directory, "mix.exs")) == ~s(version: "2026.10.20")
    end
  end

  test "sets the requested patch rather than the current day", %{directory: directory} do
    assert {output, 0} = run_script(directory, ["2026.11.0"])
    assert output =~ "Version bumped successfully to 2026.11.0"
    assert File.read!(Path.join(directory, "mix.exs")) == ~s(version: "2026.11.0")
  end

  test "fails when the checks fail", %{directory: directory} do
    File.write!(Path.join(directory, "mix"), "#!/bin/sh\nexit 7\n")
    assert {output, 7} = run_script(directory, ["2026.11.1"])
    refute output =~ "Version bumped successfully"
  end

  defp run_script(directory, args) do
    System.cmd("bash", [@script | args],
      cd: directory,
      env: [{"PATH", directory <> ":" <> System.get_env("PATH")}],
      stderr_to_stdout: true
    )
  end
end
