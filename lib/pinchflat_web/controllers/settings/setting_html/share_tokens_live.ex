defmodule Pinchflat.Settings.ShareTokensLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.Profiles
  alias Pinchflat.ShareTokens

  @impl true
  def mount(_params, session, socket) do
    tokens = ShareTokens.list_tokens()
    profiles = Profiles.list_media_profiles()
    default_profile_id = default_profile_id(profiles)
    base_url = resolve_base_url(session["base_url"])

    socket =
      socket
      |> assign(:tokens, tokens)
      |> assign(:profiles, profiles)
      |> assign(:token_name, "")
      |> assign(:expiry_days, "")
      |> assign(:selected_profile_id, default_profile_id)
      |> assign(:created_token_secret, nil)
      |> assign(:error_message, nil)
      |> assign(:base_url, base_url)
      |> assign(:bookmarklet_code, bookmarklet_js(base_url))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8">
      <%!-- Created Token Secret Callout --%>
      <div
        :if={@created_token_secret}
        id="created-token-secret-banner"
        class="theme-surface-accent border border-theme-primary/40 rounded-m3-sm p-4 sm:p-6 flex flex-col gap-3"
      >
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.icon name="hero-key" class="h-5 w-5 text-theme-primary" />
            <h4 class="min-w-0 break-words text-base font-semibold text-theme-on-surface">
              New Share Token Created: {@created_token_secret.name}
            </h4>
          </div>
          <button
            type="button"
            phx-click="dismiss_secret"
            class="theme-button theme-button-secondary shrink-0"
          >
            Dismiss
          </button>
        </div>

        <p class="text-sm text-theme-on-surface-muted">
          Copy this token now. For security, it will not be displayed again.
        </p>

        <div class="flex items-center gap-2">
          <input
            type="text"
            readonly
            id="raw-token-secret-input"
            value={@created_token_secret.secret}
            class="theme-input font-mono text-xs w-full py-2 px-3 rounded-m3-sm select-all"
            onclick="this.select()"
          />
          <button
            type="button"
            id="copy-token-secret-btn"
            class="theme-button theme-outline-button shrink-0 gap-1"
            data-copy-value={@created_token_secret.secret}
            onclick="copyTextToClipboard(this.dataset.copyValue)"
          >
            <.icon name="hero-clipboard-document" class="h-4 w-4" /> Copy
          </button>
        </div>
      </div>

      <%!-- Error Alert --%>
      <div
        :if={@error_message}
        class="theme-surface-accent border border-theme-error/40 rounded-m3-sm p-3 text-sm theme-status-error flex items-center justify-between"
      >
        <span>{@error_message}</span>
        <button
          type="button"
          phx-click="dismiss_error"
          class="text-xs text-theme-on-surface-muted hover:text-theme-on-surface"
        >
          ✕
        </button>
      </div>

      <%!-- Active Share Tokens Table --%>
      <div class="flex flex-col gap-4">
        <div class="flex items-center justify-between">
          <h4 class="text-lg font-medium text-theme-on-surface">Scoped Share Tokens</h4>
          <span class="text-xs text-theme-on-surface-muted">{length(@tokens)} configured</span>
        </div>

        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-theme-outline text-left text-theme-on-surface-muted">
                <th class="py-2.5 px-3 font-medium">Name</th>
                <th class="py-2.5 px-3 font-medium">Media Profile</th>
                <th class="py-2.5 px-3 font-medium">Created</th>
                <th class="py-2.5 px-3 font-medium">Expires</th>
                <th class="py-2.5 px-3 font-medium">Last Used</th>
                <th class="py-2.5 px-3 font-medium">Status</th>
                <th class="py-2.5 px-3 font-medium text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@tokens == []}>
                <td colspan="7" class="py-6 text-center text-theme-on-surface-muted">
                  No share tokens created yet. Create one below to enable mobile shortcuts or external tools.
                </td>
              </tr>
              <%= for token <- @tokens do %>
                <tr id={"token-row-#{token.id}"} class="border-b border-theme-outline/50 hover:bg-theme-surface-2/40">
                  <td class="py-2.5 px-3 font-medium text-theme-on-surface">{token.name}</td>
                  <td class="py-2.5 px-3 text-theme-on-surface-muted">
                    {if token.media_profile, do: token.media_profile.name, else: "Deleted Profile"}
                  </td>
                  <td class="py-2.5 px-3 text-theme-on-surface-muted font-mono text-xs">
                    {Calendar.strftime(token.inserted_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td class="py-2.5 px-3 text-theme-on-surface-muted font-mono text-xs">
                    {if token.expires_at, do: Calendar.strftime(token.expires_at, "%Y-%m-%d %H:%M UTC"), else: "Never"}
                  </td>
                  <td class="py-2.5 px-3 text-theme-on-surface-muted font-mono text-xs">
                    {if token.last_used_at, do: Calendar.strftime(token.last_used_at, "%Y-%m-%d %H:%M"), else: "Never"}
                  </td>
                  <td class="py-2.5 px-3">
                    <%= if not is_nil(token.revoked_at) do %>
                      <span class="rounded-full bg-theme-surface-4 px-2.5 py-0.5 text-xs font-medium text-theme-on-surface-muted">
                        Revoked
                      </span>
                    <% else %>
                      <%= if is_nil(token.media_profile) do %>
                        <span class="theme-badge-error rounded-full px-2.5 py-0.5 text-xs font-medium">
                          Profile Deleted
                        </span>
                      <% else %>
                        <%= if Pinchflat.ShareTokens.ShareToken.active?(token) do %>
                          <span class="theme-badge-success rounded-full px-2.5 py-0.5 text-xs font-medium">Active</span>
                        <% else %>
                          <span class="theme-badge-warning rounded-full px-2.5 py-0.5 text-xs font-medium">Expired</span>
                        <% end %>
                      <% end %>
                    <% end %>
                  </td>
                  <td class="py-2.5 px-3 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <button
                        :if={is_nil(token.revoked_at)}
                        type="button"
                        phx-click="revoke_token"
                        phx-value-id={token.id}
                        data-confirm={"Revoke '#{token.name}'? Existing in-flight downloads will finish, but no new requests will be accepted."}
                        class="theme-button theme-outline-button"
                      >
                        Revoke
                      </button>
                      <button
                        type="button"
                        phx-click="delete_token"
                        phx-value-id={token.id}
                        data-confirm={"Permanently delete token '#{token.name}'?"}
                        class="theme-button theme-button-secondary"
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Create New Token Form --%>
      <div class="theme-surface-accent rounded-m3-sm p-4 sm:p-5 flex flex-col gap-4">
        <h4 class="text-base font-medium text-theme-on-surface">Create New Share Token</h4>
        <form
          id="create-share-token-form"
          phx-submit="create_token"
          phx-change="validate_token_form"
          class="flex flex-col xl:flex-row gap-3 items-end"
        >
          <div class="flex-1 w-full flex flex-col gap-1.5">
            <label for="new-token-name" class="text-xs font-medium text-theme-on-surface-muted">
              Token Description / Client Name
            </label>
            <input
              type="text"
              id="new-token-name"
              name="name"
              value={@token_name}
              placeholder="e.g. iPhone Shortcut, Chrome Extension"
              class="theme-input text-sm py-2 px-3 rounded-m3-sm w-full"
              required
            />
          </div>

          <div class="w-full xl:w-64 flex flex-col gap-1.5">
            <label for="new-token-profile" class="text-xs font-medium text-theme-on-surface-muted">
              Bound Media Profile
            </label>
            <select
              id="new-token-profile"
              name="media_profile_id"
              class="theme-input text-sm py-2 px-3 rounded-m3-sm w-full"
            >
              <%= for profile <- @profiles do %>
                <option value={profile.id} selected={profile.id == @selected_profile_id}>
                  {profile.name}
                </option>
              <% end %>
            </select>
          </div>

          <div class="w-full xl:w-40 flex flex-col gap-1.5">
            <label for="new-token-expiry" class="text-xs font-medium text-theme-on-surface-muted">Expires after</label>
            <select id="new-token-expiry" name="expiry_days" class="theme-input text-sm py-2 px-3 rounded-m3-sm w-full">
              <option value="" selected={@expiry_days == ""}>Never</option>
              <option value="30" selected={@expiry_days == "30"}>30 days</option>
            </select>
          </div>

          <button
            type="submit"
            class="theme-button theme-primary-button shrink-0 w-full xl:w-auto"
          >
            <.icon name="hero-plus" class="mr-1 h-4 w-4" /> Create Token
          </button>
        </form>
        <p class="text-xs text-theme-on-surface-muted">
          Tokens are bound to the selected media profile. Expiry is optional. They cannot override download formats, paths, or settings. Rate limited to 10 requests per minute.
        </p>
      </div>

      <%!-- Bookmarklet Section --%>
      <div class="border-t border-theme-outline/60 pt-6 flex flex-col gap-4">
        <div class="flex items-center gap-2">
          <.icon name="hero-bookmark" class="h-5 w-5 text-theme-primary" />
          <h4 class="text-lg font-medium text-theme-on-surface">Quick Intake Bookmarklet</h4>
        </div>

        <p class="text-sm text-theme-on-surface-muted max-w-prose">
          Drag this link to your browser bookmarks bar. When viewing any YouTube video, click the bookmarklet to open Pinchflat-ngx with the video URL prefilled for review.
        </p>

        <div class="flex flex-wrap items-center gap-3">
          <a
            id="intake-bookmarklet-link"
            href={@bookmarklet_code}
            class="theme-button theme-outline-button gap-2 cursor-grab"
            onclick="return false;"
          >
            <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
            <span>Pinchflat-ngx Intake</span>
          </a>
          <span class="text-xs text-theme-on-surface-muted">
            (Drag to bookmarks bar, or copy code below)
          </span>
        </div>

        <div class="theme-surface-accent rounded-m3-sm p-3 flex flex-col gap-2">
          <div class="flex items-center justify-between text-xs text-theme-on-surface-muted">
            <span>Bookmarklet JavaScript</span>
            <button
              type="button"
              class="theme-button theme-button-secondary gap-1"
              data-copy-value={@bookmarklet_code}
              onclick="copyTextToClipboard(this.dataset.copyValue)"
            >
              <.icon name="hero-clipboard-document" class="h-3.5 w-3.5" /> Copy Code
            </button>
          </div>
          <code class="text-xs font-mono text-theme-on-surface break-all select-all">
            {@bookmarklet_code}
          </code>
        </div>

        <p class="text-xs text-theme-on-surface-muted">
          Security note: The bookmarklet contains no credentials and performs no network requests or downloads on its own. It directs your browser to the authenticated Browse page with the URL prefilled.
        </p>
      </div>

      <%!-- iOS Shortcut / API Client Guide --%>
      <div class="border-t border-theme-outline/60 pt-6 flex flex-col gap-3">
        <h4 class="text-base font-medium text-theme-on-surface">API & Shortcuts Integration</h4>
        <p class="text-sm text-theme-on-surface-muted">
          To download from Apple Shortcuts, Tasker, or curl, send a POST request with your scoped token in the Authorization header:
        </p>

        <div class="theme-surface-accent rounded-m3-sm p-3 font-mono text-xs text-theme-on-surface overflow-x-auto">
          <pre>curl -X POST "{@base_url}/api/share/intake" \
    -H "Authorization: Bearer &lt;YOUR_TOKEN&gt;" \
    -H "Content-Type: application/json" \
    -d '&#123;"url": "https://www.youtube.com/watch?v=VIDEO_ID"&#125;'</pre>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate_token_form", params, socket) do
    name = Map.get(params, "name", socket.assigns.token_name)
    profile_id = parse_profile_id(Map.get(params, "media_profile_id"))
    expiry_days = Map.get(params, "expiry_days", socket.assigns.expiry_days)

    {:noreply,
     socket
     |> assign(:token_name, name)
     |> assign(:expiry_days, expiry_days)
     |> assign(:selected_profile_id, profile_id || socket.assigns.selected_profile_id)}
  end

  @impl true
  def handle_event("create_token", params, socket) do
    name = String.trim(Map.get(params, "name", socket.assigns.token_name))
    profile_id = parse_profile_id(Map.get(params, "media_profile_id")) || socket.assigns.selected_profile_id
    expiry_days = Map.get(params, "expiry_days", socket.assigns.expiry_days)

    cond do
      name == "" ->
        {:noreply, assign(socket, :error_message, "Please provide a name for the token.")}

      is_nil(profile_id) ->
        {:noreply, assign(socket, :error_message, "Please select a media profile.")}

      expiry_days not in ["", "30"] ->
        {:noreply, assign(socket, :error_message, "Choose a valid expiry.")}

      true ->
        expires_at =
          if expiry_days == "30", do: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

        case ShareTokens.create_token(%{"name" => name, "media_profile_id" => profile_id, "expires_at" => expires_at}) do
          {:ok, token, secret} ->
            updated_tokens = ShareTokens.list_tokens()

            {:noreply,
             socket
             |> assign(:tokens, updated_tokens)
             |> assign(:created_token_secret, %{name: token.name, secret: secret})
             |> assign(:token_name, "")
             |> assign(:error_message, nil)}

          {:error, _changeset} ->
            {:noreply, assign(socket, :error_message, "Could not create share token. Please check the inputs.")}
        end
    end
  end

  @impl true
  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, :created_token_secret, nil)}
  end

  @impl true
  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_message, nil)}
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, _} ->
        case ShareTokens.revoke_token(id) do
          {:ok, _token} ->
            {:noreply, assign(socket, :tokens, ShareTokens.list_tokens())}

          _ ->
            {:noreply, assign(socket, :error_message, "Could not revoke token.")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_token", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, _} ->
        case ShareTokens.delete_token(id) do
          {:ok, _token} ->
            {:noreply, assign(socket, :tokens, ShareTokens.list_tokens())}

          _ ->
            {:noreply, assign(socket, :error_message, "Could not delete token.")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def bookmarklet_js(base_url) do
    target = Jason.encode!(base_url <> "/browse?url=")

    "javascript:(function(){var u=encodeURIComponent(window.location.href);window.open(#{target}+u,'_blank','noopener');})();"
  end

  defp default_profile_id([first | _]), do: first.id
  defp default_profile_id([]), do: nil

  defp parse_profile_id(nil), do: nil
  defp parse_profile_id(""), do: nil

  defp parse_profile_id(val) when is_binary(val) do
    case Integer.parse(val) do
      {id, _} -> id
      :error -> nil
    end
  end

  defp parse_profile_id(val) when is_integer(val), do: val

  defp resolve_base_url(request_base_url) do
    setting = Pinchflat.Settings.record()

    if setting.external_base_url && String.trim(setting.external_base_url) != "" do
      String.trim_trailing(setting.external_base_url, "/")
    else
      String.trim_trailing(request_base_url || PinchflatWeb.Endpoint.url(), "/")
    end
  end
end
