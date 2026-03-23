defmodule Pinchflat.Settings do
  @moduledoc """
  The Settings context.
  """
  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings.Setting

  @cache_key {__MODULE__, :record}

  @doc """
  Returns the only setting record. It _should_ be impossible
  to create or delete this record, so it's assertive about
  assuming it's the only one.

  Returns %Setting{}
  """
  def record do
    case cached_record() do
      %Setting{} = setting ->
        setting

      _ ->
        Setting
        |> limit(1)
        |> Repo.one()
        |> cache_record()
    end
  end

  @doc """
  Updates the setting record.

  Returns {:ok, %Setting{}} | {:error, %Ecto.Changeset{}}
  """
  def update_setting(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, %Setting{} = updated_setting} -> cache_record(updated_setting)
      _ -> :ok
    end)
  end

  @doc """
  Updates a setting, returning the new value.
  Is setup to take a keyword list argument so you
  can call it like `Settings.set(onboarding: true)`

  Returns {:ok, value} | {:error, :invalid_key} | {:error, %Ecto.Changeset{}}
  """
  def set([{attr, value}]) do
    record()
    |> update_setting(%{attr => value})
    |> case do
      {:ok, %{^attr => _}} -> {:ok, value}
      {:ok, _} -> {:error, :invalid_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Gets the value of a setting.

  Returns {:ok, value} | {:error, :invalid_key}
  """
  def get(name) do
    case Map.fetch(record(), name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_key}
    end
  end

  @doc """
  Gets the value of a setting, raising if it doesn't exist.

  Returns value
  """
  def get!(name) do
    case get(name) do
      {:ok, value} -> value
      {:error, _} -> raise "Setting `#{name}` not found"
    end
  end

  @doc """
  Returns `%Ecto.Changeset{}`
  """
  def change_setting(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, attrs)
  end

  defp cached_record do
    if cache_enabled?() do
      :persistent_term.get(@cache_key, nil)
    end
  end

  defp cache_record(%Setting{} = setting) do
    if cache_enabled?() do
      :persistent_term.put(@cache_key, setting)
    end

    setting
  end

  defp cache_record(setting), do: setting

  defp cache_enabled? do
    default_enabled = if function_exported?(Mix, :env, 0), do: Mix.env() != :test, else: true
    Application.get_env(:pinchflat, :settings_cache, default_enabled)
  end
end
