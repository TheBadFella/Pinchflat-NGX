defmodule PinchflatWeb.MediaProfiles.MediaProfileController do
  use PinchflatWeb, :controller
  use Pinchflat.Sources.SourcesQuery
  use Pinchflat.Profiles.ProfilesQuery

  alias Pinchflat.Repo
  alias Pinchflat.Profiles
  alias Pinchflat.Reconciliation
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Profiles.MediaProfileDeletionWorker
  alias Pinchflat.Settings.YtDlpConfigFile
  alias PinchflatWeb.YtDlpOptionsHelpers

  def index(conn, _params) do
    media_profiles_query =
      from mp in MediaProfile,
        as: :media_profile,
        where: is_nil(mp.marked_for_deletion_at),
        order_by: [asc: mp.name],
        select: map(mp, ^MediaProfile.__schema__(:fields)),
        select_merge: %{
          source_count:
            subquery(
              from s in Source,
                where: s.media_profile_id == parent_as(:media_profile).id,
                select: count(s.id)
            )
        }

    render(conn, :index, media_profiles: Repo.all(media_profiles_query))
  end

  def new(conn, params) do
    # Preload an existing media profile for faster creation
    cs_struct =
      case to_string(params["template_id"]) do
        "" -> %MediaProfile{}
        template_id -> Repo.get(MediaProfile, template_id) || %MediaProfile{}
      end

    changeset =
      Profiles.change_media_profile(%MediaProfile{
        cs_struct
        | id: nil,
          name: nil,
          marked_for_deletion_at: nil
      })

    render_profile(conn, :new, changeset, profile_options(), layout: get_onboarding_layout())
  end

  def create(conn, %{"media_profile" => media_profile_params} = params) do
    opts = YtDlpOptionsHelpers.options_opts(params, :missing)

    case Profiles.create_media_profile(media_profile_params, opts) do
      {:ok, media_profile} ->
        redirect_location =
          if Settings.get!(:onboarding), do: ~p"/?onboarding=1", else: ~p"/media_profiles/#{media_profile}"

        conn
        |> put_flash(:info, "Media profile created successfully.")
        |> redirect(to: redirect_location)

      {:error, %Ecto.Changeset{} = changeset} ->
        render_profile(conn, :new, changeset, submitted_profile_options(params, nil, nil, :missing),
          layout: get_onboarding_layout()
        )

      {:error, %Ecto.Changeset{} = changeset, reason} ->
        render_profile(
          conn,
          :new,
          changeset,
          submitted_profile_options(params, reason, nil, :missing),
          layout: get_onboarding_layout()
        )
    end
  end

  def show(conn, %{"id" => id}) do
    media_profile = Profiles.get_media_profile!(id)
    active_tab = tab_param(conn.params, ~w(media-profile sources), "media-profile")

    sources =
      SourcesQuery.new()
      |> where(^SourcesQuery.for_media_profile(media_profile))
      |> order_by(asc: :custom_name)
      |> Repo.all()

    render(conn, :show,
      media_profile: media_profile,
      sources: sources,
      active_tab: active_tab,
      tab_href: fn tab -> ~p"/media_profiles/#{media_profile}?#{[tab: tab]}" end
    )
  end

  def edit(conn, %{"id" => id}) do
    media_profile = Profiles.get_media_profile!(id)
    changeset = Profiles.change_media_profile(media_profile)
    options = YtDlpOptionsHelpers.load_assigns(:profile, media_profile.id, profile_inherited())

    render_profile(conn, :edit, changeset, options, media_profile: media_profile)
  end

  def update(conn, %{"id" => id, "media_profile" => media_profile_params} = params) do
    media_profile = Profiles.get_media_profile!(id)
    opts = YtDlpOptionsHelpers.options_opts(params, :any)

    case Profiles.update_media_profile(media_profile, media_profile_params, opts) do
      {:ok, media_profile} ->
        # Profile changes can alter predicted paths, invalidating any staged reconcile plan
        Reconciliation.mark_ready_plans_stale()

        conn
        |> put_flash(:info, "Media profile updated successfully.")
        |> redirect(to: ~p"/media_profiles/#{media_profile}")

      {:error, %Ecto.Changeset{} = changeset} ->
        options = submitted_profile_options(params, nil, media_profile.id, :any)
        render_profile(conn, :edit, changeset, options, media_profile: media_profile)

      {:error, %Ecto.Changeset{} = changeset, reason} ->
        options = submitted_profile_options(params, reason, media_profile.id, :any)
        render_profile(conn, :edit, changeset, options, media_profile: media_profile)
    end
  end

  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    media_profile = Profiles.get_media_profile!(id)

    if Pinchflat.MediaWatch.deletion_blocked?(media_profile) do
      conn
      |> put_flash(
        :error,
        "End watch protection for this profile's watched videos before deleting the profile. Download any saved originals you want to keep first."
      )
      |> redirect(to: ~p"/media_profiles/#{media_profile}")
    else
      {:ok, _} = Profiles.update_media_profile(media_profile, %{marked_for_deletion_at: DateTime.utc_now()})
      MediaProfileDeletionWorker.kickoff(media_profile, %{delete_files: delete_files})

      conn
      |> put_flash(:info, "Media Profile deletion started. This may take a while to complete.")
      |> redirect(to: ~p"/media_profiles")
    end
  end

  defp render_profile(conn, template, changeset, options, extra) do
    render(conn, template, Keyword.merge(extra, [changeset: changeset] ++ Map.to_list(options)))
  end

  defp profile_inherited, do: %{base: YtDlpConfigFile.present?()}

  defp profile_options do
    Map.put(YtDlpOptionsHelpers.base_assigns(), :yt_dlp_options_inherited, profile_inherited())
  end

  defp submitted_profile_options(params, reason, profile_id, default_version) do
    error = if reason, do: YtDlpOptionsHelpers.message(reason)

    options =
      YtDlpOptionsHelpers.submitted_assigns(
        params,
        profile_inherited(),
        %{},
        error,
        default_version
      )

    if reason == :stale_conflict and is_integer(profile_id) do
      case YtDlpConfigFile.read_scope(:profile, profile_id) do
        {:ok, %{version: version}} -> %{options | yt_dlp_options_version: version}
        _ -> options
      end
    else
      options
    end
  end

  defp get_onboarding_layout do
    if Settings.get!(:onboarding) do
      {Layouts, :onboarding}
    else
      {Layouts, :app}
    end
  end

  defp tab_param(params, allowed_tabs, default_tab) do
    tab = params["tab"]

    if tab in allowed_tabs do
      tab
    else
      default_tab
    end
  end
end
