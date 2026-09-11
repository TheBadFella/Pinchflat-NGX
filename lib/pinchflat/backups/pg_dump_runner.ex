defmodule Pinchflat.Backups.PgDumpRunner do
  @moduledoc """
  Runs `pg_dump` through PinchYT's cancellation-aware command wrapper.

  This module deliberately does not log command arguments, environment values,
  or command output. The caller is responsible for logging a redacted summary
  when a dump fails.
  """

  require Logger

  @doc "Returns the configured `pg_dump` executable, if installed."
  @spec executable() :: String.t() | nil
  def executable do
    Application.get_env(:pinchflat, :pg_dump_executable) || System.find_executable("pg_dump")
  end

  @doc "Returns the fixed, non-secret pg_dump arguments."
  @spec args(String.t(), String.t()) :: [String.t()]
  def args(partial_path, database) do
    [
      "--format=custom",
      "--no-owner",
      "--no-privileges",
      "--no-password",
      "--file",
      partial_path,
      "--dbname",
      database
    ]
  end

  @doc """
  Runs pg_dump with connection values supplied through `PG*` environment
  variables. The wrapper terminates the child when its owning process closes
  stdin, which lets cancellation leave no live pg_dump process behind.
  """
  @spec run(String.t(), [String.t()], [{String.t(), String.t()}], String.t()) ::
          {String.t(), non_neg_integer()}
  def run(executable, args, env, working_directory) do
    wrapper = Path.join(:code.priv_dir(:pinchflat), "cmd_wrapper.sh")

    {output, status} =
      System.cmd(wrapper, [executable | args],
        cd: working_directory,
        env: env,
        stderr_to_stdout: true
      )

    Logger.debug("PostgreSQL pg_dump exited with status #{status}")
    {output, status}
  rescue
    _error -> {"pg_dump could not be started", 127}
  end
end
