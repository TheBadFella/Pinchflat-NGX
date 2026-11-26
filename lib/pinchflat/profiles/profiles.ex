defmodule Pinchflat.Profiles do
  @moduledoc """
  The Profiles context.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Settings.ScopedYtDlpOptions
  alias Pinchflat.Settings.Setting
  alias Pinchflat.Sources
  alias Pinchflat.Profiles.MediaProfile

  @doc """
  Returns the list of media_profiles.

  Returns [%MediaProfile{}, ...]
  """
  def list_media_profiles do
    Repo.all(MediaProfile)
  end

  @doc """
  Gets a single media_profile.

  Returns %MediaProfile{}. Raises `Ecto.NoResultsError` if the Media profile does not exist.
  """
  def get_media_profile!(id), do: Repo.get!(MediaProfile, id)

  @doc """
  Resolves the configured default media profile ID from available profiles,
  ignoring missing or deletion-pending profiles.

  Returns integer() | nil
  """
  def default_media_profile_id(profiles \\ nil) do
    case Settings.get!(:default_media_profile_id) do
      nil ->
        nil

      profile_id when is_list(profiles) ->
        case Enum.find(profiles, &(&1.id == profile_id and is_nil(&1.marked_for_deletion_at))) do
          %MediaProfile{id: id} -> id
          _ -> nil
        end

      profile_id ->
        from(p in MediaProfile,
          where: p.id == ^profile_id and is_nil(p.marked_for_deletion_at),
          select: p.id
        )
        |> Repo.one()
    end
  end

  @doc """
  Sets the given profile as the default media profile if it exists and is not
  marked for deletion.

  Returns {:ok, %MediaProfile{}} | {:error, :unavailable | %Ecto.Changeset{}}
  """
  def set_default_media_profile(%MediaProfile{id: id}), do: set_default_media_profile(id)

  def set_default_media_profile(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed_id, ""} -> set_default_media_profile(parsed_id)
      _ -> {:error, :unavailable}
    end
  end

  def set_default_media_profile(id) when is_integer(id) do
    result =
      Repo.transaction(fn ->
        case from(p in MediaProfile, where: p.id == ^id and is_nil(p.marked_for_deletion_at)) |> Repo.one() do
          nil ->
            Repo.rollback(:unavailable)

          %MediaProfile{} = profile ->
            case Settings.update_setting(Settings.record(), %{default_media_profile_id: profile.id}) do
              {:ok, _setting} -> profile
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, %MediaProfile{} = profile} ->
        Settings.refresh_cache()
        {:ok, profile}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_default_media_profile(_), do: {:error, :unavailable}

  @doc """
  Creates a media_profile, optionally saving its scoped yt-dlp options and
  updating the default media profile in the same transaction. A file or
  transaction failure rolls back the profile and preserves the prior default.

  Returns {:ok, %MediaProfile{}} | {:error, %Ecto.Changeset{}} |
  {:error, %Ecto.Changeset{}, reason}
  """
  def create_media_profile(attrs, opts \\ []) do
    payload = ScopedYtDlpOptions.payload(opts)
    make_default = Keyword.get(opts, :make_default, false) == true
    changeset = MediaProfile.changeset(%MediaProfile{}, attrs)

    if payload == :absent and not make_default do
      Repo.insert(changeset)
    else
      expected = ScopedYtDlpOptions.expected_version(opts, :missing)

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:media_profile, changeset)
        |> maybe_save_profile_options(payload, expected)
        |> maybe_set_default_in_multi(make_default)

      case Repo.transaction(multi) do
        {:ok, %{media_profile: profile}} ->
          if make_default, do: Settings.refresh_cache()
          {:ok, profile}

        {:error, :media_profile, error_changeset, _changes} ->
          {:error, error_changeset}

        {:error, :yt_dlp_options, reason, %{media_profile: profile}} ->
          ScopedYtDlpOptions.restore(:profile, profile.id, :missing, payload)
          {:error, %{changeset | action: :insert}, reason}

        {:error, :commit, reason, %{media_profile: profile}} ->
          if payload != :absent, do: ScopedYtDlpOptions.restore(:profile, profile.id, :missing, payload)
          {:error, %{changeset | action: :insert}, reason}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp maybe_save_profile_options(multi, :absent, _expected), do: multi

  defp maybe_save_profile_options(multi, payload, expected) do
    Ecto.Multi.run(multi, :yt_dlp_options, fn _repo, %{media_profile: profile} ->
      case ScopedYtDlpOptions.save(payload, :profile, profile.id, expected) do
        :ok -> {:ok, :saved}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp maybe_set_default_in_multi(multi, false), do: multi

  defp maybe_set_default_in_multi(multi, true) do
    Ecto.Multi.run(multi, :default_setting, fn repo, %{media_profile: profile} ->
      setting = Setting |> limit(1) |> repo.one!()

      setting
      |> Setting.changeset(%{default_media_profile_id: profile.id})
      |> repo.update(log: false)
    end)
  end

  @doc """
  Updates a media_profile, optionally saving its scoped yt-dlp options in the
  same transaction. A file failure rolls back the profile update.

  Returns {:ok, %MediaProfile{}} | {:error, %Ecto.Changeset{}} |
  {:error, %Ecto.Changeset{}, reason}
  """
  def update_media_profile(%MediaProfile{} = media_profile, attrs, opts \\ []) do
    payload = ScopedYtDlpOptions.payload(opts)
    changeset = MediaProfile.changeset(media_profile, attrs)

    if payload == :absent do
      Repo.update(changeset)
    else
      expected = ScopedYtDlpOptions.expected_version(opts, :any)
      prior = ScopedYtDlpOptions.prior(:profile, media_profile.id)

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.update(:media_profile, changeset)
        |> Ecto.Multi.run(:yt_dlp_options, fn _repo, %{media_profile: updated} ->
          case ScopedYtDlpOptions.save(payload, :profile, updated.id, expected) do
            :ok -> {:ok, :saved}
            {:error, reason} -> {:error, reason}
          end
        end)

      case Repo.transaction(multi) do
        {:ok, %{media_profile: updated}} ->
          {:ok, updated}

        {:error, :media_profile, error_changeset, _changes} ->
          {:error, error_changeset}

        {:error, :yt_dlp_options, reason, %{media_profile: updated}} ->
          ScopedYtDlpOptions.restore(:profile, updated.id, prior, payload)
          {:error, %{changeset | action: :update}, reason}

        {:error, :commit, reason, %{media_profile: updated}} ->
          ScopedYtDlpOptions.restore(:profile, updated.id, prior, payload)
          {:error, %{changeset | action: :update}, reason}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a media_profile, all its sources, and all their media items.
  Can optionally delete the media files.

  Returns {:ok, %MediaProfile{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_profile(%MediaProfile{} = media_profile, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)
    sources = Sources.list_sources_for(media_profile)

    watched? = Pinchflat.MediaWatch.deletion_blocked?(media_profile)

    result =
      if watched? do
        {:error, :watch_tombstone_required}
      else
        Enum.reduce_while(sources, :ok, fn source, :ok ->
          case Sources.delete_source(source, delete_files: delete_files) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok ->
            res = Repo.delete(media_profile)
            if match?({:ok, _}, res), do: Settings.invalidate_cache()
            res

          error ->
            error
        end
      end

    if match?({:error, reason} when reason in [:watch_hold, :watch_tombstone_required], result) do
      Repo.update_all(from(p in MediaProfile, where: p.id == ^media_profile.id), set: [marked_for_deletion_at: nil])
    end

    result
  end

  @doc """
  Returns `%Ecto.Changeset{}`
  """
  def change_media_profile(%MediaProfile{} = media_profile, attrs \\ %{}) do
    MediaProfile.changeset(media_profile, attrs)
  end
end
