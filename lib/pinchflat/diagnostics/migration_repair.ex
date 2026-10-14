defmodule Pinchflat.Diagnostics.MigrationRepair do
  @moduledoc """
  Bounded, previewable repair operations for existing Pinchflat-NGX installations.

  Guarantees:
  - All repair actions require an explicit pre-execution preview.
  - Source names are restored ONLY from authoritative backup data or explicit user input.
  - Lost names are NEVER guessed from video titles or heuristics.
  - User lock/unlock preferences are preserved unless explicitly instructed.
  - File checks never trigger reference clearing or deletion of media items.
  - Previews validate state fresh at application time to prevent applying stale proposals.
  - All repair operations are idempotent, cancellable, and track active preview tokens.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Pinchflat.Diagnostics.MigrationRepair.TokenStore
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  @doc """
  Builds an immutable, previewable plan for restoring source custom names
  from authoritative backup entries.

  Accepts:
  - Map of `%{source_id => original_name}`
  - List of maps `[%{id: id, custom_name: name, collection_id: ...}, ...]`
  - List of tuples `[{id, name}, ...]`

  Opts:
  - `:lock` - optional boolean override for `custom_name_locked`

  Returns `{:ok, preview_map}` or `{:error, reason}`.
  """
  def preview_restore_source_names(backup_entries, opts \\ []) do
    normalized = normalize_backup_entries(backup_entries)
    lock_opts_override = Keyword.get(opts, :lock, nil)

    {to_update, already_matching, not_found, mismatched_identity, invalid_names} =
      Enum.reduce(
        normalized,
        {[], [], [], [], []},
        fn entry, acc ->
          process_restore_entry(entry, acc, lock_opts_override)
        end
      )

    token = generate_preview_token({:restore_source_names, to_update})

    preview = %{
      action: :restore_source_names,
      token: token,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      to_update: Enum.reverse(to_update),
      already_matching: Enum.reverse(already_matching),
      not_found: Enum.reverse(not_found),
      mismatched_identity: Enum.reverse(mismatched_identity),
      invalid_names: Enum.reverse(invalid_names),
      total_proposals: length(to_update)
    }

    TokenStore.register(token, :restore_source_names, preview)

    {:ok, preview}
  end

  @doc """
  Applies a confirmed source name restoration preview.

  Validates fresh state before modifying each row. If a source's name or lock state was
  changed between preview and apply (stale preview), the row is skipped.
  """
  def apply_restore_source_names(preview, opts \\ []) do
    token = Map.get(preview, :token)

    case validate_token(token, :restore_source_names) do
      :ok ->
        strict = Keyword.get(opts, :strict, false)
        results = Enum.map(preview.to_update, &apply_single_name_restore(&1, strict))

        TokenStore.update_status(token, :applied)

        applied_count = Enum.count(results, &match?({:ok, _, _}, &1))
        skipped_count = Enum.count(results, &match?({:skipped, _, _}, &1))
        error_count = Enum.count(results, &match?({:error, _, _}, &1))

        {:ok,
         %{
           action: :restore_source_names,
           applied: applied_count,
           skipped: skipped_count,
           errors: error_count,
           results: results
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds a preview plan to protect explicitly selected unlocked sources.
  Preserves user choice by requiring an explicit list of source IDs.
  """
  def preview_protect_unlocked_sources(source_ids) when is_list(source_ids) do
    sources = Repo.all(from s in Source, where: s.id in ^source_ids)

    {to_update, already_locked} =
      Enum.reduce(sources, {[], []}, fn source, {updates, locked} ->
        if source.custom_name_locked do
          entry = %{id: source.id, custom_name: source.custom_name, status: :already_locked}
          {updates, [entry | locked]}
        else
          entry = %{
            id: source.id,
            custom_name: source.custom_name,
            current_locked: false,
            proposed_locked: true,
            collection_id: source.collection_id,
            status: :pending_lock
          }

          {[entry | updates], locked}
        end
      end)

    token = generate_preview_token({:protect_unlocked_sources, to_update})

    preview = %{
      action: :protect_unlocked_sources,
      token: token,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      to_update: Enum.reverse(to_update),
      already_locked: Enum.reverse(already_locked),
      total_proposals: length(to_update)
    }

    TokenStore.register(token, :protect_unlocked_sources, preview)

    {:ok, preview}
  end

  @doc """
  Applies an unlocked source protection preview.
  Validates that source was not edited after preview was generated.
  """
  def apply_protect_unlocked_sources(preview, _opts \\ []) do
    token = Map.get(preview, :token)

    case validate_token(token, :protect_unlocked_sources) do
      :ok ->
        results = Enum.map(preview.to_update, &apply_single_source_lock/1)

        TokenStore.update_status(token, :applied)

        applied_count = Enum.count(results, &match?({:ok, _, _}, &1))
        skipped_count = Enum.count(results, &match?({:skipped, _, _}, &1))
        error_count = Enum.count(results, &match?({:error, _, _}, &1))

        {:ok,
         %{
           action: :protect_unlocked_sources,
           applied: applied_count,
           skipped: skipped_count,
           errors: error_count,
           results: results
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Safely cancels a proposed repair plan without making any database or filesystem changes.
  """
  def cancel_repair(%{token: token}) when is_binary(token) do
    TokenStore.update_status(token, :cancelled)
    Logger.info("[MigrationRepair] Cancelled repair plan with token: #{token}")
    {:ok, :cancelled}
  end

  def cancel_repair(%{token: token}) do
    token_str = to_string(token)
    TokenStore.update_status(token_str, :cancelled)
    Logger.info("[MigrationRepair] Cancelled repair plan with token: #{token_str}")
    {:ok, :cancelled}
  end

  def cancel_repair(_), do: {:ok, :cancelled}

  # --- Internal Helpers ---

  defp process_restore_entry(entry, {updates, matching, missing, mismatched, invalid}, lock_opts) do
    proposed_name = entry.proposed_name

    cond do
      is_nil(proposed_name) or String.trim(proposed_name) == "" ->
        {updates, matching, missing, mismatched, [%{entry: entry, reason: :blank_name} | invalid]}

      is_nil(entry.id) and is_nil(entry.expected_collection_id) ->
        {updates, matching, [%{entry: entry, reason: :missing_identity} | missing], mismatched, invalid}

      true ->
        evaluate_source_for_restore(entry, {updates, matching, missing, mismatched, invalid}, lock_opts)
    end
  end

  defp evaluate_source_for_restore(entry, {updates, matching, missing, mismatched, invalid}, lock_opts) do
    case find_source_by_identity(entry) do
      nil ->
        {updates, matching, [%{id: entry.id, proposed_name: entry.proposed_name} | missing], mismatched, invalid}

      %Source{} = src ->
        categorize_source_proposal(src, entry, {updates, matching, missing, mismatched, invalid}, lock_opts)
    end
  end

  defp categorize_source_proposal(src, entry, {updates, matching, missing, mismatched, invalid}, lock_opts) do
    case check_source_identity_match(src, entry) do
      {:error, reason, expected, actual} ->
        mismatch_entry = %{
          id: src.id,
          proposed_name: entry.proposed_name,
          reason: reason,
          expected: expected,
          actual: actual
        }

        {updates, matching, missing, [mismatch_entry | mismatched], invalid}

      :ok ->
        add_matching_or_update(src, entry, {updates, matching, missing, mismatched, invalid}, lock_opts)
    end
  end

  defp add_matching_or_update(src, entry, {updates, matching, missing, mismatched, invalid}, lock_opts) do
    if src.custom_name == entry.proposed_name do
      match_entry = %{id: src.id, current_name: src.custom_name, status: :already_matching}
      {updates, [match_entry | matching], missing, mismatched, invalid}
    else
      will_lock = resolve_lock_state(src, entry.lock_override, lock_opts)

      update_entry = %{
        id: src.id,
        current_name: src.custom_name,
        proposed_name: entry.proposed_name,
        current_locked: src.custom_name_locked,
        will_lock: will_lock,
        collection_id: src.collection_id,
        status: :pending_restore
      }

      {[update_entry | updates], matching, missing, mismatched, invalid}
    end
  end

  defp resolve_lock_state(src, entry_lock, opts_lock) do
    cond do
      is_boolean(entry_lock) -> entry_lock
      is_boolean(opts_lock) -> opts_lock
      true -> src.custom_name_locked
    end
  end

  defp apply_single_name_restore(item, strict) do
    case Repo.get(Source, item.id) do
      nil ->
        {:error, item.id, :not_found}

      %Source{} = source ->
        validate_and_commit_restore(source, item, strict)
    end
  end

  defp validate_and_commit_restore(source, item, strict) do
    cond do
      source.custom_name != item.current_name ->
        Logger.warning(
          "[MigrationRepair] Stale preview name for source ##{source.id}: expected '#{item.current_name}', found '#{source.custom_name}'"
        )

        if strict, do: {:error, source.id, :stale_preview}, else: {:skipped, source.id, :stale_preview}

      source.custom_name_locked != item.current_locked ->
        Logger.warning(
          "[MigrationRepair] Stale preview lock state for source ##{source.id}: expected #{item.current_locked}, found #{source.custom_name_locked}"
        )

        if strict, do: {:error, source.id, :stale_preview}, else: {:skipped, source.id, :stale_preview}

      Map.has_key?(item, :collection_id) and source.collection_id != item.collection_id ->
        Logger.warning(
          "[MigrationRepair] Collection ID mismatch for source ##{source.id}: expected '#{item.collection_id}', found '#{source.collection_id}'"
        )

        {:error, source.id, :identity_mismatch}

      true ->
        commit_source_name_restore(source, item)
    end
  end

  defp commit_source_name_restore(source, item) do
    changeset =
      Source.changeset(
        source,
        %{
          custom_name: item.proposed_name,
          custom_name_locked: item.will_lock
        },
        :initial
      )

    case Repo.update(changeset) do
      {:ok, updated} ->
        Logger.info(
          "[MigrationRepair] Restored source ##{source.id} name to '#{updated.custom_name}' (locked: #{updated.custom_name_locked})"
        )

        {:ok, updated.id, updated.custom_name}

      {:error, changeset} ->
        {:error, source.id, changeset}
    end
  end

  defp apply_single_source_lock(item) do
    case Repo.get(Source, item.id) do
      nil ->
        {:error, item.id, :not_found}

      %Source{} = source ->
        validate_and_commit_source_lock(source, item)
    end
  end

  defp validate_and_commit_source_lock(source, item) do
    cond do
      source.custom_name_locked == true ->
        {:skipped, source.id, :already_locked}

      source.custom_name != item.custom_name ->
        Logger.warning(
          "[MigrationRepair] Source ##{source.id} was edited since preview (expected '#{item.custom_name}', found '#{source.custom_name}'); skipping lock."
        )

        {:skipped, source.id, :stale_preview}

      true ->
        changeset = Source.changeset(source, %{custom_name_locked: true}, :initial)

        case Repo.update(changeset) do
          {:ok, updated} ->
            {:ok, updated.id, :locked}

          {:error, changeset} ->
            {:error, source.id, changeset}
        end
    end
  end

  defp validate_token(nil, _expected_action), do: {:error, :missing_token}

  defp validate_token(token, expected_action) do
    case TokenStore.lookup(token) do
      {:ok, :cancelled, _action, _data} ->
        {:error, :cancelled}

      {:ok, :applied, _action, _data} ->
        {:error, :already_applied}

      {:ok, :active, ^expected_action, _data} ->
        :ok

      {:ok, :active, other_action, _data} ->
        {:error, {:action_mismatch, other_action}}

      {:error, :not_found} ->
        {:error, :invalid_token}
    end
  end

  defp find_source_by_identity(%{id: id}) when is_integer(id), do: Repo.get(Source, id)

  defp find_source_by_identity(%{expected_collection_id: cid}) when is_binary(cid) and cid != "" do
    Repo.get_by(Source, collection_id: cid)
  end

  defp find_source_by_identity(_), do: nil

  defp check_source_identity_match(%Source{} = source, entry) do
    expected_cid = entry.expected_collection_id
    expected_uuid = entry.expected_uuid
    expected_url = entry.expected_url

    cond do
      is_binary(expected_cid) and expected_cid != "" and source.collection_id != expected_cid ->
        {:error, :collection_id_mismatch, expected_cid, source.collection_id}

      is_binary(expected_uuid) and expected_uuid != "" and source.uuid != expected_uuid ->
        {:error, :uuid_mismatch, expected_uuid, source.uuid}

      is_binary(expected_url) and expected_url != "" and source.original_url != expected_url ->
        {:error, :url_mismatch, expected_url, source.original_url}

      true ->
        :ok
    end
  end

  defp normalize_backup_entries(entries) when is_map(entries) do
    Enum.map(entries, fn {k, v} ->
      %{
        id: normalize_id(k),
        proposed_name: to_string(v),
        expected_collection_id: nil,
        expected_uuid: nil,
        expected_url: nil,
        lock_override: nil
      }
    end)
  end

  defp normalize_backup_entries(entries) when is_list(entries) do
    Enum.map(entries, fn
      %{id: id, custom_name: name} = map ->
        %{
          id: normalize_id(id),
          proposed_name: to_string(name),
          expected_collection_id: map[:collection_id] || map["collection_id"],
          expected_uuid: map[:uuid] || map["uuid"],
          expected_url: map[:original_url] || map["original_url"],
          lock_override: map[:lock] || map["lock"] || map[:custom_name_locked] || map["custom_name_locked"]
        }

      %{"id" => id, "custom_name" => name} = map ->
        %{
          id: normalize_id(id),
          proposed_name: to_string(name),
          expected_collection_id: map["collection_id"] || map[:collection_id],
          expected_uuid: map["uuid"] || map[:uuid],
          expected_url: map["original_url"] || map[:original_url],
          lock_override: map["lock"] || map[:lock] || map["custom_name_locked"] || map[:custom_name_locked]
        }

      {id, name} ->
        %{
          id: normalize_id(id),
          proposed_name: to_string(name),
          expected_collection_id: nil,
          expected_uuid: nil,
          expected_url: nil,
          lock_override: nil
        }
    end)
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {num, ""} -> num
      _ -> id
    end
  end

  defp normalize_id(nil), do: nil

  defp generate_preview_token(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary({DateTime.utc_now(), term, System.unique_integer([:positive])}))
    |> Base.encode16(case: :lower)
  end
end
