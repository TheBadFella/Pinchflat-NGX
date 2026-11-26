defmodule PinchflatWeb.CommandPaletteLive do
  @moduledoc """
  Global search and navigation palette, opened from the sidebar Search button,
  the phone bar, `Ctrl/Cmd+K` or `/`.

  The `CommandPalette` hook owns visibility, keyboard movement and focus. This
  LiveView only answers queries, so a closed palette never touches the database.
  """

  use PinchflatWeb, :live_view

  alias Pinchflat.Media
  alias Pinchflat.Profiles
  alias Pinchflat.Sources

  @scopes ~w(all media sources pages)
  @media_min_length 2
  @all_limits %{media: 6, sources: 4, profiles: 4, pages: 4}
  @single_scope_limits %{media: 20, sources: 10, profiles: 10, pages: 10}

  @pages [
    %{name: "Sources", detail: "Page", icon: "hero-tv", path: "/sources", keywords: "sources channels playlists"},
    %{
      name: "Add a source",
      detail: "Action",
      icon: "hero-plus",
      path: "/sources/new",
      keywords: "new add source channel"
    },
    %{
      name: "Channel Discovery",
      detail: "Page",
      icon: "hero-magnifying-glass",
      path: "/discovery",
      keywords: "discovery discover find channels"
    },
    %{name: "Browse YouTube", detail: "Page", icon: "hero-globe-alt", path: "/browse", keywords: "browse youtube"},
    %{
      name: "Media Profiles",
      detail: "Page",
      icon: "hero-adjustments-vertical",
      path: "/media_profiles",
      keywords: "media profiles quality format"
    },
    %{
      name: "Settings",
      detail: "Config",
      icon: "hero-cog-6-tooth",
      path: "/settings",
      keywords: "settings config cookies yt-dlp"
    },
    %{
      name: "PostgreSQL Backups",
      detail: "Config",
      icon: "hero-cog-6-tooth",
      path: "/backups",
      keywords: "postgresql postgres backups"
    },
    %{
      name: "PostgreSQL Migration",
      detail: "Config",
      icon: "hero-cog-6-tooth",
      path: "/postgres_migration",
      keywords: "postgresql postgres migration"
    },
    %{
      name: "File Reconciliation",
      detail: "Config",
      icon: "hero-cog-6-tooth",
      path: "/reconciliation",
      keywords: "file reconciliation reconcile"
    },
    %{
      name: "Diagnostics",
      detail: "Config",
      icon: "hero-cog-6-tooth",
      path: "/diagnostics",
      keywords: "diagnostics database logs"
    }
  ]

  # A blank query only lists pages, so mounting and resetting never query the database.
  def mount(_params, _session, socket) do
    {:ok, run_search(socket, "", "all")}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, run_search(socket, query, socket.assigns.scope)}
  end

  def handle_event("scope", %{"scope" => scope}, socket) when scope in @scopes do
    {:noreply, run_search(socket, socket.assigns.query, scope)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, run_search(socket, "", "all")}
  end

  def render(assigns) do
    ~H"""
    <div id="command-palette-root" phx-hook="CommandPalette">
      <div data-palette-scrim class="theme-palette-scrim" style="display: none;"></div>
      <div
        data-palette-dialog
        class="theme-palette"
        style="display: none;"
        role="dialog"
        aria-modal="true"
        aria-label="Search"
      >
        <form
          id="command-palette-form"
          class="theme-palette-input-row"
          autocomplete="off"
        >
          <.icon name="hero-magnifying-glass" class="h-5 w-5 shrink-0 text-theme-on-surface-muted" />
          <label for="command-palette-input" class="sr-only">Search media, sources, profiles and pages</label>
          <input
            id="command-palette-input"
            data-palette-input
            type="text"
            name="query"
            phx-update="ignore"
            spellcheck="false"
            role="combobox"
            aria-expanded="true"
            aria-controls="command-palette-results"
            aria-autocomplete="list"
            placeholder="Search media, sources, profiles and pages"
            class="theme-palette-input"
          />
          <button
            :if={@query != ""}
            type="button"
            data-palette-clear
            class="theme-field-action"
            aria-label="Clear search"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
          <button type="button" data-palette-cancel class="theme-palette-cancel">Cancel</button>
        </form>

        <div class="theme-palette-scopes" role="group" aria-label="Limit results to">
          <button
            :for={
              {value, label} <- [
                {"all", "Everything"},
                {"media", "Media"},
                {"sources", "Sources"},
                {"pages", "Pages and actions"}
              ]
            }
            type="button"
            class="theme-palette-chip"
            phx-click="scope"
            phx-value-scope={value}
            data-palette-scope
            aria-pressed={to_string(@scope == value)}
          >
            {label}
          </button>
        </div>

        <div id="command-palette-results" class="theme-palette-body" role="listbox" aria-label="Results">
          <div :for={group <- @groups} role="group" aria-label={group.title}>
            <div class="theme-palette-group-title">{group.title}</div>
            <.palette_option :for={item <- group.items} item={item} query={@query} />
          </div>

          <p :if={short_media_query?(@query, @scope)} class="theme-palette-note">
            Type at least 2 characters to search media.
          </p>

          <p :if={String.trim(@query) == ""} class="theme-palette-note">
            Search looks at media titles, descriptions and source names, plus media profiles and pages.
          </p>

          <div :if={String.trim(@query) != "" && @groups == []} class="theme-palette-empty">
            <p class="font-semibold text-theme-on-surface">Nothing matches "{String.trim(@query)}"</p>
            <p>
              Search looks at media titles, descriptions and source names, plus media profiles and pages. Media that
              has not been indexed yet will not appear. To find a channel that is not in your library, use <.link
                href={~p"/browse"}
                class="text-theme-primary underline"
              >Browse</.link>.
            </p>
          </div>
        </div>

        <div class="theme-palette-footer">
          <span class="theme-palette-key-hint"><kbd class="theme-kbd">↑</kbd> <kbd class="theme-kbd">↓</kbd> to move</span>
          <span class="theme-palette-key-hint"><kbd class="theme-kbd">Enter</kbd> to open</span>
          <span class="theme-palette-key-hint"><kbd class="theme-kbd">Esc</kbd> to close</span>
          <span class="flex-1"></span>
          <span aria-live="polite">{status_text(@query, @result_count)}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :query, :string, required: true

  defp palette_option(%{item: %{kind: :media}} = assigns) do
    ~H"""
    <a href={@item.href} role="option" tabindex="-1" class="theme-palette-option" aria-selected="false">
      <.media_thumbnail media_item={@item.media_item} size="mini" />
      <span class="min-w-0 flex-1">
        <.palette_title text={@item.title} query={@query} />
        <span class="theme-palette-option-detail">
          <span>{@item.source_name}</span><span :if={@item.published_at}>, published
          <.datetime_in_zone
            datetime={@item.published_at}
            format="%Y-%m-%d"
          /></span><span :if={@item.downloaded_at}>, downloaded
          <.datetime_in_zone
            datetime={@item.downloaded_at}
            format="%Y-%m-%d"
          /></span>
          <span class={["theme-palette-status-inline", status_class(@item.downloaded?)]}>
            {status_label(@item.downloaded?)}
          </span>
        </span>
      </span>
      <span class={["theme-download-status", status_class(@item.downloaded?)]}>{status_label(@item.downloaded?)}</span>
      <kbd class="theme-kbd theme-palette-enter-hint">Enter</kbd>
    </a>
    """
  end

  defp palette_option(%{item: %{kind: :see_all}} = assigns) do
    ~H"""
    <a href={@item.href} role="option" tabindex="-1" class="theme-palette-option" aria-selected="false">
      <span class="theme-palette-glyph"><.icon name="hero-magnifying-glass" class="h-5 w-5" /></span>
      <span class="min-w-0 flex-1 text-theme-primary">{@item.title}</span>
      <kbd class="theme-kbd theme-palette-enter-hint">Enter</kbd>
    </a>
    """
  end

  defp palette_option(assigns) do
    ~H"""
    <a href={@item.href} role="option" tabindex="-1" class="theme-palette-option" aria-selected="false">
      <span :if={@item.kind == :source} class="theme-palette-avatar" aria-hidden="true">{initial(@item.title)}</span>
      <span :if={@item.kind != :source} class="theme-palette-glyph" aria-hidden="true">
        <.icon name={@item.icon} class="h-5 w-5" />
      </span>
      <span class="min-w-0 flex-1">
        <.palette_title text={@item.title} query={@query} />
        <span :if={@item.detail} class="theme-palette-option-detail">{@item.detail}</span>
      </span>
      <kbd class="theme-kbd theme-palette-enter-hint">Enter</kbd>
    </a>
    """
  end

  attr :text, :string, required: true
  attr :query, :string, required: true

  defp palette_title(assigns) do
    parts =
      Enum.map(highlight_parts(assigns.text, assigns.query), fn {text, marked?} ->
        {:safe, escaped} = Phoenix.HTML.html_escape(text)

        if marked?, do: [~s(<mark class="theme-palette-mark">), escaped, "</mark>"], else: escaped
      end)

    assigns = assign(assigns, :highlighted_title, {:safe, parts})

    ~H"""
    <span class="theme-palette-option-title">{@highlighted_title}</span>
    """
  end

  @doc false
  # Splits `text` around the first case-insensitive occurrence of `query`.
  # Text whose length changes when downcased is returned unhighlighted rather than mis-sliced.
  def highlight_parts(text, query) do
    text = text || ""
    needle = query |> to_string() |> String.trim() |> String.downcase()
    haystack = String.downcase(text)

    with true <- needle != "",
         true <- byte_size(haystack) == byte_size(text),
         {start, length} <- :binary.match(haystack, needle) do
      [
        {binary_part(text, 0, start), false},
        {binary_part(text, start, length), true},
        {binary_part(text, start + length, byte_size(text) - start - length), false}
      ]
      |> Enum.reject(fn {part, _} -> part == "" end)
    else
      _ -> [{text, false}]
    end
  end

  defp run_search(socket, query, scope) do
    query = String.slice(query || "", 0, 200)
    term = String.trim(query)
    limits = if scope == "all", do: @all_limits, else: @single_scope_limits

    groups =
      if term == "" do
        [pages_group("Go to", Enum.take(@pages, 5))]
      else
        media = scope in ["all", "media"] && media_group(term, limits.media)

        video_source_ids =
          for %{media_item: %{source: %{collection_type: :video}, source_id: id}} <- (media && media.items) || [],
              do: id

        [
          scope in ["all", "sources"] && sources_group(term, limits.sources, video_source_ids),
          media,
          scope in ["all", "sources"] && profiles_group(term, limits.profiles),
          scope in ["all", "pages"] && pages_group("Pages and actions", matching_pages(term, limits.pages))
        ]
        |> Enum.filter(&(&1 && &1.items != []))
      end

    count = if term == "", do: 0, else: groups |> Enum.flat_map(& &1.items) |> Enum.count(&(&1.kind != :see_all))

    assign(socket, query: query, scope: scope, groups: groups, result_count: count)
  end

  defp media_group(term, limit) do
    if String.length(term) < @media_min_length do
      nil
    else
      items =
        term
        |> Media.search(limit: limit, include_source_names: true)
        |> Enum.map(&media_item/1)

      see_all =
        if items == [],
          do: [],
          else: [
            %{
              kind: :see_all,
              title: ~s(See all media results for "#{term}"),
              href: ~p"/search?#{[q: term, source_names: "true"]}"
            }
          ]

      %{title: "Media", items: items ++ see_all}
    end
  end

  defp media_item(media_item) do
    %{
      kind: :media,
      title: media_item.title,
      href: ~p"/sources/#{media_item.source_id}/media/#{media_item.id}",
      media_item: media_item,
      source_name: media_item.source && String.trim(media_item.source.custom_name || ""),
      published_at: media_item.uploaded_at,
      downloaded_at: media_item.media_filepath && media_item.media_downloaded_at,
      downloaded?: is_binary(media_item.media_filepath)
    }
  end

  defp sources_group(term, limit, excluded_ids) do
    items =
      term
      |> Sources.search_sources(limit: limit, exclude_ids: excluded_ids)
      |> Enum.map(fn source ->
        %{
          kind: :source,
          title: source.custom_name || source.collection_name || "Source ##{source.id}",
          detail: source_detail(source),
          href: ~p"/sources/#{source.id}"
        }
      end)

    %{title: "Sources", items: items}
  end

  defp profiles_group(term, limit) do
    items =
      term
      |> Profiles.search_media_profiles(limit: limit)
      |> Enum.map(fn profile ->
        %{
          kind: :profile,
          title: profile.name,
          detail: nil,
          icon: "hero-adjustments-vertical",
          href: ~p"/media_profiles/#{profile.id}"
        }
      end)

    %{title: "Media profiles", items: items}
  end

  defp pages_group(title, pages) do
    items = Enum.map(pages, &%{kind: :page, title: &1.name, detail: &1.detail, icon: &1.icon, href: &1.path})
    %{title: title, items: items}
  end

  defp matching_pages(term, limit) do
    needle = String.downcase(term)

    @pages
    |> Enum.filter(fn page -> String.contains?(String.downcase(page.name <> " " <> page.keywords), needle) end)
    |> Enum.take(limit)
  end

  defp source_detail(source) do
    type =
      case source.collection_type do
        :channel -> "Channel"
        :playlist -> "Playlist"
        :video -> "Single video"
        _ -> "Source"
      end

    if source.collection_name && source.collection_name != source.custom_name do
      "#{type}, #{source.collection_name}"
    else
      type
    end
  end

  defp short_media_query?(query, scope) do
    term = String.trim(query)
    scope in ["all", "media"] and term != "" and String.length(term) < @media_min_length
  end

  defp status_label(true), do: "Downloaded"
  defp status_label(false), do: "Not downloaded"

  defp status_class(true), do: "theme-download-status-ok"
  defp status_class(false), do: "theme-download-status-waiting"

  defp status_text(query, count) do
    cond do
      String.trim(query) == "" -> ""
      count == 0 -> "No results"
      count == 1 -> "1 result shown"
      true -> "#{count} results shown"
    end
  end

  defp initial(name) do
    case Regex.run(~r/[[:alnum:]]/u, name || "") do
      [char] -> String.upcase(char)
      _ -> "?"
    end
  end
end
