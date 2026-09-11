defmodule Pinchflat.Backups.Connection do
  @moduledoc """
  Builds the environment used by `pg_dump` from the configured database URL.

  PostgreSQL's client tools read connection details from the standard `PG*`
  environment variables. Keeping the password there avoids putting a
  `DATABASE_URL` on the process command line or in command logs.
  """

  @type connection :: %{
          database: String.t(),
          env: [{String.t(), String.t()}],
          secrets: [String.t()]
        }

  @doc """
  Parses a PostgreSQL or Ecto database URL into `pg_dump` environment values.

  Returns `{:ok, connection}` or `{:error, reason}`. The returned connection
  contains the password only in the environment list and secret-redaction
  metadata; callers must not render or log it.
  """
  @spec from_url(String.t() | nil) :: {:ok, connection()} | {:error, atom()}
  def from_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with true <- uri.scheme in ["ecto", "postgres", "postgresql"],
         {:ok, database} <- database_name(uri),
         {:ok, user, password} <- userinfo(uri) do
      env =
        [
          optional_env("PGHOST", uri.host),
          optional_env("PGPORT", uri.port),
          optional_env("PGUSER", user),
          optional_env("PGPASSWORD", password),
          {:ok, {"PGDATABASE", database}},
          sslmode_env(uri)
        ]
        |> Enum.flat_map(fn
          {:ok, value} -> [value]
          :skip -> []
        end)

      secrets =
        [password, url]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))

      {:ok, %{database: database, env: env, secrets: secrets}}
    else
      false -> {:error, :unsupported_database_url}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_url(_url), do: {:error, :database_url_missing}

  @doc "Returns the configured `DATABASE_URL` without exposing it to callers."
  @spec configured_url() :: String.t() | nil
  def configured_url do
    System.get_env("DATABASE_URL") ||
      Application.get_env(:pinchflat, Pinchflat.Repo, [])[:url]
  end

  @doc "Builds connection details from the configured database URL."
  @spec configured() :: {:ok, connection()} | {:error, atom()}
  def configured, do: from_url(configured_url())

  @doc "Redacts configured connection secrets from command output."
  @spec redact(String.t(), connection()) :: String.t()
  def redact(output, %{secrets: secrets}) when is_binary(output) do
    output
    |> redact_uri_password()
    |> then(&Enum.reduce(secrets, &1, fn secret, acc -> String.replace(acc, secret, "[REDACTED]") end))
  end

  def redact(output, _connection), do: output

  defp database_name(%URI{path: path}) when is_binary(path) do
    database = path |> String.trim_leading("/") |> URI.decode()

    if database == "", do: {:error, :database_name_missing}, else: {:ok, database}
  end

  defp database_name(_uri), do: {:error, :database_name_missing}

  defp userinfo(%URI{userinfo: nil}), do: {:ok, nil, nil}

  defp userinfo(%URI{userinfo: userinfo}) do
    case String.split(userinfo, ":", parts: 2) do
      [user] -> {:ok, URI.decode(user), nil}
      [user, password] -> {:ok, URI.decode(user), URI.decode(password)}
    end
  end

  defp optional_env(_name, nil), do: :skip
  defp optional_env(_name, ""), do: :skip
  defp optional_env(name, value), do: {:ok, {name, to_string(value)}}

  defp sslmode_env(%URI{query: nil}), do: :skip

  defp sslmode_env(%URI{query: query}) do
    case URI.decode_query(query)["sslmode"] do
      nil -> :skip
      "" -> :skip
      sslmode -> {:ok, {"PGSSLMODE", sslmode}}
    end
  end

  defp redact_uri_password(output) do
    Regex.replace(
      ~r/(?<scheme>ecto|postgres|postgresql):\/\/(?<user>[^:\/\s]+):(?<password>[^@\/\s]+)@/,
      output,
      fn _, scheme, user, _password -> "#{scheme}://#{user}:[REDACTED]@" end
    )
  end
end
