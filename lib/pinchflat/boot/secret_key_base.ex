defmodule Pinchflat.Boot.SecretKeyBase do
  @moduledoc """
  Resolves the endpoint's secret key base at boot.

  Called from `config/runtime.exs`, so it must only use the standard library.
  """

  @file_name ".secret_key_base"

  @doc """
  Returns the secret key base to use.

  An explicit `SECRET_KEY_BASE` wins. Self-hosted installs without one get a
  random key generated on first boot and stored in the config directory, so
  every install has its own key and sessions survive restarts.

  Returns a string, or raises when no key can be resolved.
  """
  def resolve(env_value, run_context, config_path) do
    cond do
      is_binary(env_value) and env_value != "" -> env_value
      run_context == "selfhosted" -> read_or_generate(Path.join(config_path, @file_name))
      true -> raise "environment variable SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"
    end
  end

  defp read_or_generate(path) do
    stored =
      case File.read(path) do
        {:ok, contents} -> String.trim(contents)
        {:error, _} -> ""
      end

    if byte_size(stored) >= 64, do: stored, else: generate(path)
  end

  defp generate(path) do
    key = 64 |> :crypto.strong_rand_bytes() |> Base.encode64()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.write(path, key) do
      key
    else
      {:error, reason} ->
        raise "could not store a generated secret key at #{path} (#{:file.format_error(reason)}). " <>
                "Make the config directory writable or set SECRET_KEY_BASE."
    end
  end
end
