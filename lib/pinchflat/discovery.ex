defmodule Pinchflat.Discovery do
  @moduledoc """
  The channel discovery context.

  Suggestions are keyed by the stable external channel ID. Every generator
  feeds the same normalization, exclusion, validation, scoring, and idempotent
  persistence path. Dismissed and accepted suggestions remain terminal so a
  later scan cannot silently make them visible again.
  """

  import Ecto.Query, warn: false
  alias Pinchflat.Discovery.Candidate
  alias Pinchflat.Discovery.FeaturedGenerator
  alias Pinchflat.Discovery.MentionGenerator
  alias Pinchflat.Discovery.Normalizer
  alias Pinchflat.Discovery.Sample
  alias Pinchflat.Discovery.Scoring
  alias Pinchflat.Discovery.Suggestion
  alias Pinchflat.Discovery.Validator
  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source

  @visible_states [:candidate, :validated]
  @terminal_states [:dismissed, :accepted]
  @max_evidence_length 512
  @max_generators_count 16
  @max_generators_length 256
  @max_score 100
  @max_channel_name_length 200
  @max_url_length 2_048
  @default_sample_size 12
  @default_pool_size 50
  @default_max_candidates 100

  @completion_topic "channel_discovery"
  @completion_event "scan_completed"

  @doc """
  Returns visible suggestions ordered by descending score and stable ID.

  Terminal suggestions are excluded unless `include_terminal: true` or an
  explicit `states:` option is supplied.
  """
  def list_suggestions(opts \\ []) do
    states = states_for_listing(opts)

    Suggestion
    |> where([suggestion], suggestion.state in ^states)
    |> order_by([suggestion], desc: suggestion.score, asc: suggestion.id)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc """
  Returns all dismissed suggestions.
  """
  def list_dismissed_suggestions, do: list_suggestions(states: [:dismissed])

  @doc """
  Gets a suggestion by its database ID.

  Raises `Ecto.NoResultsError` when the suggestion does not exist.
  """
  def get_suggestion!(id), do: Repo.get!(Suggestion, id)

  @doc """
  Gets a suggestion by its database ID, or returns nil.
  """
  def get_suggestion(id), do: Repo.get(Suggestion, id)

  @doc """
  Gets a suggestion by its stable external channel ID.
  """
  def get_suggestion_by_external_channel_id(external_channel_id) do
    Repo.get_by(Suggestion, external_channel_id: external_channel_id)
  end

  @doc """
  Returns external channel IDs that must not be suggested again.

  This includes subscribed channel sources and terminal suggestions. Values are
  stable IDs, not display names or mutable URLs.
  """
  def excluded_channel_ids do
    (existing_source_channel_ids() ++ terminal_suggestion_channel_ids())
    |> Enum.uniq()
  end

  @doc """
  Returns the PubSub topic used for scan completion notifications.
  """
  def completion_topic, do: @completion_topic

  @doc """
  Returns the event name used for scan completion notifications.
  """
  def completion_event, do: @completion_event

  @doc """
  Subscribes the caller to discovery scan completion broadcasts.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Pinchflat.PubSub, @completion_topic)

  @doc """
  Normalizes raw generator references into candidates and deduplicates evidence.
  """
  def normalize_candidates(references, generator, opts \\ []) when is_list(references) do
    self_references = Keyword.get(opts, :self_references, [])
    self_keys = self_reference_keys(self_references)

    references
    |> Enum.flat_map(fn
      %Candidate{} = candidate ->
        reference_key = if is_map(candidate.reference), do: Map.get(candidate.reference, :key), else: nil

        if reference_key in self_keys do
          []
        else
          [add_generator(candidate, generator)]
        end

      reference ->
        case Normalizer.normalize_reference(reference, self_references: self_references) do
          nil ->
            []

          normalized ->
            attrs = if is_map(reference), do: reference, else: %{}
            [Candidate.from_reference(normalized, generator, attrs)]
        end
    end)
    |> Candidate.deduplicate()
  end

  @doc """
  Excludes candidates matching existing subscribed channels or dismissed rows.

  `:existing_sources` and `:dismissed_suggestions` may be supplied as lists to
  keep this function useful in isolated tests. Without them, the local database
  is queried.
  """
  def exclude_candidates(candidates, opts \\ []) when is_list(candidates) do
    existing_sources = Keyword.get_lazy(opts, :existing_sources, &list_existing_channel_sources/0)
    dismissed_suggestions = Keyword.get_lazy(opts, :dismissed_suggestions, &list_dismissed_suggestion_records/0)

    excluded =
      (Enum.flat_map(existing_sources, &identity_records/1) ++ Enum.flat_map(dismissed_suggestions, &identity_records/1))
      |> Enum.reduce(%{keys: MapSet.new(), ids: MapSet.new(), urls: MapSet.new()}, &add_identity/2)

    Enum.reject(candidates, fn %Candidate{} = candidate -> excluded_candidate?(candidate, excluded) end)
  end

  @doc """
  Inserts or updates a suggestion by `external_channel_id`.

  Existing dismissed or accepted rows are returned unchanged. Evidence,
  generator provenance, and scores are bounded before persistence, and a
  validated row receives a validation timestamp on its first insert.
  """
  def upsert_suggestion(%Candidate{} = candidate), do: upsert_suggestion(candidate_attrs(candidate))

  def upsert_suggestion(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    cond do
      blank?(attrs.external_channel_id) ->
        {:error, Suggestion.changeset(%Suggestion{}, attrs)}

      not Normalizer.valid_channel_id?(attrs.external_channel_id) ->
        {:error, :invalid_channel_id}

      attrs.external_channel_id in existing_source_channel_ids() ->
        {:error, :existing_source}

      true ->
        do_upsert(attrs.external_channel_id, attrs)
    end
  end

  @doc """
  Compatibility alias for callers that treat the first persistence as a create.
  """
  def create_suggestion(attrs), do: upsert_suggestion(attrs)

  @doc """
  Returns a changeset for a suggestion without persisting it.
  """
  def change_suggestion(%Suggestion{} = suggestion, attrs \\ %{}) do
    Suggestion.changeset(suggestion, attrs)
  end

  @doc """
  Updates a suggestion using its schema changeset.
  """
  def update_suggestion(%Suggestion{} = suggestion, attrs) do
    suggestion
    |> Suggestion.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks a suggestion as dismissed.

  An already accepted suggestion remains accepted.
  """
  def dismiss_suggestion(%Suggestion{state: :accepted} = suggestion), do: {:ok, suggestion}
  def dismiss_suggestion(%Suggestion{} = suggestion), do: update_suggestion(suggestion, %{state: :dismissed})
  def dismiss_suggestion(id), do: id |> get_suggestion!() |> dismiss_suggestion()

  @doc """
  Marks a suggestion as accepted.

  An already dismissed suggestion remains dismissed.
  """
  def accept_suggestion(%Suggestion{state: :dismissed} = suggestion), do: {:ok, suggestion}
  def accept_suggestion(%Suggestion{} = suggestion), do: update_suggestion(suggestion, %{state: :accepted})
  def accept_suggestion(id), do: id |> get_suggestion!() |> accept_suggestion()

  @doc """
  Restores a dismissed suggestion to the validated state.
  """
  def restore_suggestion(%Suggestion{state: :dismissed} = suggestion),
    do: update_suggestion(suggestion, %{state: :validated})

  def restore_suggestion(%Suggestion{} = suggestion), do: {:ok, suggestion}
  def restore_suggestion(id), do: id |> get_suggestion!() |> restore_suggestion()

  @doc """
  Runs the bounded discovery pipeline and persists validated suggestions.

  The scan respects the global and per-generator settings by default. Pass
  `manual: true` to run an explicit scan even while the scheduled feature gate
  is disabled. Generator functions, source lists, validation, and randomness
  remain injectable for focused tests.
  """
  def scan(opts \\ []) do
    result = do_scan(opts)

    if Keyword.get(opts, :broadcast, false) do
      broadcast_completion(completion_payload(result))
    end

    result
  end

  @doc """
  Persists validated candidates without creating duplicate rows.
  """
  def persist_suggestions(candidates, opts \\ []) when is_list(candidates) do
    now = Keyword.get(opts, :now) || now()

    Enum.reduce_while(candidates, {:ok, []}, fn %Candidate{} = candidate, {:ok, persisted} ->
      attrs = candidate_attrs(candidate) |> Map.put(:state, :validated) |> Map.put(:validated_at, now)

      case upsert_suggestion(attrs) do
        {:ok, suggestion} -> {:cont, {:ok, [suggestion | persisted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, suggestions} -> {:ok, Enum.reverse(suggestions)}
      error -> error
    end
  end

  @doc """
  Selects a bounded random display sample from persisted validated suggestions.
  """
  def sample_suggestions(opts \\ []) do
    sample_size = Keyword.get(opts, :sample_size, default(:sample_size) || @default_sample_size)
    pool_size = Keyword.get(opts, :pool_size, default(:sample_pool_size) || @default_pool_size)
    random_fun = Keyword.get(opts, :random_fun, &Enum.take_random/2)

    list_suggestions(states: [:validated], limit: pool_size)
    |> Enum.map(&candidate_from_suggestion/1)
    |> Sample.select(sample_size, max_pool: pool_size, random_fun: random_fun, score_fun: & &1.score)
  end

  @doc """
  Broadcasts a safe completion payload to discovery subscribers.
  """
  def broadcast_completion(payload) when is_map(payload) do
    Phoenix.PubSub.broadcast(
      Pinchflat.PubSub,
      @completion_topic,
      %Phoenix.Socket.Broadcast{topic: @completion_topic, event: @completion_event, payload: payload}
    )
  end

  @doc """
  Returns the maximum evidence length applied by the context.
  """
  def max_evidence_length, do: @max_evidence_length

  @doc """
  Returns the maximum generator provenance length applied by the context.
  """
  def max_generators_length, do: @max_generators_length

  @doc """
  Returns the maximum score applied by the context.
  """
  def max_score, do: @max_score

  defp do_scan(opts) do
    manual? = Keyword.get(opts, :manual, false)
    enabled? = Keyword.get_lazy(opts, :enabled, fn -> Settings.get!(:channel_discovery_enabled) end)

    if not manual? and not enabled? do
      {:ok, disabled_result()}
    else
      run_enabled_scan(opts)
    end
  end

  defp run_enabled_scan(opts) do
    generator_opts = Keyword.get(opts, :generator_opts, [])

    max_candidates =
      bounded_integer(
        Keyword.get(opts, :max_candidates, default(:max_candidates) || @default_max_candidates),
        @default_max_candidates
      )

    {generator_candidates, generator_errors} =
      [:mention, :featured]
      |> Enum.reduce({[], []}, fn generator, {candidates, errors} ->
        if generator_enabled?(generator, opts) do
          case run_generator(generator, opts, generator_opts) do
            {:ok, generated} -> {candidates ++ normalize_candidates(generated, generator), errors}
            {:error, reason} -> {candidates, [%{generator: generator, reason: safe_reason(reason)} | errors]}
          end
        else
          {candidates, errors}
        end
      end)

    candidates =
      generator_candidates
      |> Candidate.deduplicate()
      |> exclude_candidates(opts)
      |> Enum.take(max_candidates)
      |> exclude_recently_validated(opts)

    validation_opts = Keyword.get(opts, :validation_opts, [])
    validation = Validator.validate(candidates, validation_opts)

    validated_candidates =
      validation.validated
      |> Candidate.deduplicate()
      |> exclude_candidates(opts)
      |> Enum.map(fn candidate -> Candidate.with_score(candidate, Scoring.score(candidate)) end)

    persist_opts = if Keyword.has_key?(opts, :now), do: [now: Keyword.get(opts, :now)], else: []

    with {:ok, suggestions} <- persist_suggestions(validated_candidates, persist_opts) do
      {:ok,
       %{
         status: :completed,
         candidate_count: length(candidates),
         validated_count: length(validated_candidates),
         inserted_count: length(suggestions),
         generator_errors: Enum.reverse(generator_errors),
         validation_rejections: rejection_counts(validation.rejected),
         suggestions: suggestions
       }}
    end
  end

  defp run_generator(:mention, opts, generator_opts) do
    invoke_generator(generator_fun(opts, :mention), generator_opts, &MentionGenerator.generate/1)
  end

  defp run_generator(:featured, opts, generator_opts) do
    invoke_generator(generator_fun(opts, :featured), generator_opts, &FeaturedGenerator.generate/1)
  end

  defp invoke_generator(nil, generator_opts, default_fun), do: safe_call(fn -> default_fun.(generator_opts) end)

  defp invoke_generator(fun, generator_opts, _default_fun) when is_function(fun, 1),
    do: safe_call(fn -> fun.(generator_opts) end)

  defp invoke_generator(fun, _generator_opts, _default_fun) when is_function(fun, 0), do: safe_call(fun)
  defp invoke_generator(_fun, _generator_opts, _default_fun), do: {:error, :generator_failed}

  defp safe_call(fun) do
    case fun.() do
      {:ok, candidates} when is_list(candidates) -> {:ok, candidates}
      candidates when is_list(candidates) -> {:ok, candidates}
      {:error, reason} -> {:error, safe_reason(reason)}
      _ -> {:error, :generator_failed}
    end
  rescue
    _error -> {:error, :generator_failed}
  catch
    :exit, _reason -> {:error, :generator_failed}
  end

  defp generator_fun(opts, generator) do
    opts
    |> Keyword.get(:generator_funs, %{})
    |> Map.get(generator)
  end

  defp generator_enabled?(:mention, opts) do
    Keyword.get_lazy(opts, :mentions_enabled, fn -> Settings.get!(:channel_discovery_mentions_enabled) end)
  end

  defp generator_enabled?(:featured, opts) do
    Keyword.get_lazy(opts, :featured_enabled, fn -> Settings.get!(:channel_discovery_featured_enabled) end)
  end

  defp add_generator(%Candidate{} = candidate, generator) do
    %{candidate | generators: Enum.uniq([to_string(generator) | List.wrap(candidate.generators)])}
  end

  defp self_reference_keys(references) do
    references
    |> List.wrap()
    |> Enum.flat_map(fn reference ->
      case Normalizer.normalize_reference(reference) do
        %{key: key} -> [key]
        nil -> []
      end
    end)
    |> MapSet.new()
  end

  defp exclude_recently_validated(candidates, opts) do
    refresh_after =
      bounded_integer(
        Keyword.get(
          opts,
          :validation_refresh_after_seconds,
          default(:validation_refresh_after_seconds) || 86_400
        ),
        86_400
      )

    if refresh_after == 0 do
      candidates
    else
      now = Keyword.get(opts, :now) || now()
      channel_ids = candidates |> Enum.map(& &1.external_channel_id) |> Enum.filter(&is_binary/1) |> Enum.uniq()

      if channel_ids == [] do
        candidates
      else
        recently_validated_ids =
          opts
          |> Keyword.get_lazy(:existing_suggestions, fn -> recently_validated_suggestions(channel_ids) end)
          |> Enum.filter(&recently_validated?(&1, now, refresh_after))
          |> Enum.map(&value_for(&1, :external_channel_id))
          |> MapSet.new()

        Enum.reject(candidates, &MapSet.member?(recently_validated_ids, &1.external_channel_id))
      end
    end
  end

  defp recently_validated_suggestions(channel_ids) do
    Repo.all(
      from suggestion in Suggestion,
        where: suggestion.state == ^:validated and suggestion.external_channel_id in ^channel_ids,
        select: %{
          external_channel_id: suggestion.external_channel_id,
          state: suggestion.state,
          validated_at: suggestion.validated_at
        }
    )
  end

  defp recently_validated?(suggestion, now, refresh_after) do
    state = value_for(suggestion, :state)
    validated_at = value_for(suggestion, :validated_at)

    state in [:validated, "validated"] and is_struct(validated_at, DateTime) and
      DateTime.diff(now, validated_at, :second) < refresh_after
  end

  defp list_existing_channel_sources do
    Repo.all(from source in Source, where: source.collection_type == ^:channel)
  end

  defp list_dismissed_suggestion_records do
    Repo.all(from suggestion in Suggestion, where: suggestion.state in ^@terminal_states)
  end

  defp identity_records(%Source{} = source) do
    [
      %{
        collection_id: source.collection_id,
        canonical_url: source.original_url,
        external_channel_id: source.collection_id
      }
    ]
  end

  defp identity_records(%Suggestion{} = suggestion) do
    [
      %{
        collection_id: nil,
        canonical_url: suggestion.canonical_url,
        external_channel_id: suggestion.external_channel_id
      }
    ]
  end

  defp identity_records(source) when is_map(source), do: [source]
  defp identity_records(_source), do: []

  defp add_identity(record, excluded) do
    refs = [
      identity_value(record, :external_channel_id),
      identity_value(record, :collection_id),
      identity_value(record, :canonical_url) || identity_value(record, :original_url)
    ]

    Enum.reduce(refs, excluded, fn
      value, acc when is_binary(value) ->
        case Normalizer.normalize_reference(value) do
          %{key: key} = reference ->
            acc
            |> Map.update!(:keys, &MapSet.put(&1, key))
            |> maybe_add_id(reference)
            |> maybe_add_url(reference)

          nil ->
            if String.starts_with?(value, "http"), do: Map.update!(acc, :urls, &MapSet.put(&1, value)), else: acc
        end

      _value, acc ->
        acc
    end)
  end

  defp identity_value(record, key), do: Map.get(record, key, Map.get(record, Atom.to_string(key)))

  defp maybe_add_id(acc, %{external_channel_id: id}) when is_binary(id),
    do: Map.update!(acc, :ids, &MapSet.put(&1, id))

  defp maybe_add_id(acc, _reference), do: acc

  defp maybe_add_url(acc, %{canonical_url: url}) when is_binary(url),
    do: Map.update!(acc, :urls, &MapSet.put(&1, url))

  defp maybe_add_url(acc, _reference), do: acc

  defp excluded_candidate?(%Candidate{} = candidate, excluded) do
    reference_key = if is_map(candidate.reference), do: Map.get(candidate.reference, :key), else: nil

    reference_key in excluded.keys or
      candidate.external_channel_id in excluded.ids or
      candidate.canonical_url in excluded.urls
  end

  defp existing_source_channel_ids do
    from(source in Source,
      where: source.collection_type == ^:channel and not is_nil(source.collection_id),
      select: source.collection_id
    )
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
  end

  defp terminal_suggestion_channel_ids do
    from(suggestion in Suggestion,
      where: suggestion.state in ^@terminal_states,
      select: suggestion.external_channel_id
    )
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
  end

  defp do_upsert(external_channel_id, attrs) do
    case get_suggestion_by_external_channel_id(external_channel_id) do
      nil -> insert_suggestion(attrs)
      %Suggestion{state: state} = suggestion when state in @terminal_states -> {:ok, suggestion}
      %Suggestion{} = suggestion -> update_existing_suggestion(suggestion, attrs)
    end
  end

  defp insert_suggestion(attrs) do
    attrs = maybe_set_validation_timestamp(attrs)
    changeset = Suggestion.changeset(%Suggestion{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:external_channel_id]) do
      {:ok, %Suggestion{id: nil}} -> do_upsert(attrs.external_channel_id, attrs)
      result -> result
    end
  end

  defp update_existing_suggestion(%Suggestion{} = suggestion, attrs) do
    state = merge_state(suggestion.state, attrs.state)

    attrs =
      attrs
      |> Map.put(:state, state)
      |> maybe_preserve_validation_timestamp(suggestion)

    suggestion
    |> Suggestion.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_set_validation_timestamp(%{state: :validated} = attrs),
    do: Map.put_new(attrs, :validated_at, now())

  defp maybe_set_validation_timestamp(attrs), do: attrs

  defp maybe_preserve_validation_timestamp(%{validated_at: nil} = attrs, %Suggestion{validated_at: nil}) do
    if attrs.state == :validated, do: Map.put(attrs, :validated_at, now()), else: attrs
  end

  defp maybe_preserve_validation_timestamp(attrs, %Suggestion{validated_at: validated_at}) do
    if Map.has_key?(attrs, :validated_at), do: attrs, else: Map.put(attrs, :validated_at, validated_at)
  end

  defp merge_state(:candidate, :validated), do: :validated
  defp merge_state(state, _incoming_state), do: state

  defp normalize_attrs(attrs) do
    external_channel_id = attrs |> value_for(:external_channel_id) |> normalize_string()
    state = normalize_state(value_for(attrs, :state))

    normalized = %{
      external_channel_id: external_channel_id,
      canonical_url:
        bounded_string(value_for(attrs, :canonical_url), @max_url_length) || canonical_url(external_channel_id),
      channel_name: bounded_string(value_for(attrs, :channel_name), @max_channel_name_length) || external_channel_id,
      artwork_url: bounded_string(value_for(attrs, :artwork_url), @max_url_length),
      evidence: bounded_evidence(value_for(attrs, :evidence)),
      score: bounded_score(value_for(attrs, :score)),
      state: state
    }

    normalized
    |> maybe_put_validated_at(attrs)
    |> maybe_put_generators(attrs)
  end

  defp maybe_put_validated_at(normalized, attrs) do
    if has_key?(attrs, :validated_at),
      do: Map.put(normalized, :validated_at, value_for(attrs, :validated_at)),
      else: normalized
  end

  defp maybe_put_generators(normalized, attrs) do
    if has_key?(attrs, :generators),
      do: Map.put(normalized, :generators, bounded_generators(value_for(attrs, :generators))),
      else: normalized
  end

  defp candidate_attrs(%Candidate{} = candidate) do
    handle = if is_map(candidate.reference), do: Map.get(candidate.reference, :handle), else: nil

    %{
      external_channel_id: candidate.external_channel_id,
      canonical_url: candidate.canonical_url,
      channel_name: candidate.channel_name || handle || candidate.external_channel_id,
      artwork_url: candidate.artwork_url,
      evidence: Candidate.evidence(candidate),
      generators: candidate.generators,
      score: Scoring.score(candidate),
      state: :candidate
    }
  end

  defp candidate_from_suggestion(%Suggestion{} = suggestion) do
    reference = %{
      kind: :channel_id,
      key: "channel_id:" <> suggestion.external_channel_id,
      external_channel_id: suggestion.external_channel_id,
      handle: nil,
      canonical_url: suggestion.canonical_url
    }

    %Candidate{
      reference: reference,
      canonical_url: suggestion.canonical_url,
      external_channel_id: suggestion.external_channel_id,
      channel_name: suggestion.channel_name,
      artwork_url: suggestion.artwork_url,
      evidence: suggestion.evidence,
      score: suggestion.score,
      generators: parse_generators(suggestion.generators),
      mentions: 0
    }
  end

  defp rejection_counts(rejections), do: rejections |> Enum.map(& &1.reason) |> Enum.frequencies()

  defp disabled_result do
    %{
      status: :disabled,
      candidate_count: 0,
      validated_count: 0,
      inserted_count: 0,
      generator_errors: [],
      validation_rejections: %{},
      suggestions: []
    }
  end

  defp completion_payload({:ok, result}) do
    Map.take(result, [
      :status,
      :candidate_count,
      :validated_count,
      :inserted_count,
      :generator_errors,
      :validation_rejections
    ])
  end

  defp completion_payload({:error, _reason}),
    do: %{status: :failed, candidate_count: 0, validated_count: 0, inserted_count: 0}

  defp states_for_listing(opts) do
    cond do
      Keyword.has_key?(opts, :states) -> normalize_states(Keyword.get(opts, :states))
      Keyword.get(opts, :include_terminal, false) -> Suggestion.states()
      true -> @visible_states
    end
  end

  defp normalize_states(states) do
    states |> List.wrap() |> Enum.map(&normalize_state/1) |> Enum.filter(&(&1 in Suggestion.states())) |> Enum.uniq()
  end

  defp normalize_state(nil), do: :validated
  defp normalize_state(state) when state in [:candidate, :validated, :dismissed, :accepted], do: state

  defp normalize_state(state) when is_binary(state) do
    Enum.find(Suggestion.states(), state, &(Atom.to_string(&1) == state))
  end

  defp normalize_state(state), do: state

  defp bounded_evidence(nil), do: ""

  defp bounded_evidence(evidence) when is_list(evidence) do
    evidence |> Enum.map_join(", ", &to_string/1) |> bounded_evidence()
  end

  defp bounded_evidence(evidence), do: evidence |> to_string() |> String.trim() |> String.slice(0, @max_evidence_length)

  defp bounded_generators(nil), do: ""

  defp bounded_generators(generators) when is_list(generators) do
    generators
    |> Enum.map_join(",", &to_string/1)
    |> bounded_generators()
  end

  defp bounded_generators(generators) do
    generators
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_generators_count)
    |> Enum.join(",")
    |> String.slice(0, @max_generators_length)
  end

  defp parse_generators(generators) do
    generators
    |> bounded_generators()
    |> String.split(",", trim: true)
  end

  defp bounded_score(score) when is_integer(score), do: score |> max(0) |> min(@max_score)

  defp bounded_score(score) when is_binary(score) do
    case Integer.parse(score) do
      {score, ""} -> bounded_score(score)
      _ -> 0
    end
  end

  defp bounded_score(_score), do: 0

  defp canonical_url(nil), do: nil
  defp canonical_url(external_channel_id), do: Normalizer.channel_url(external_channel_id)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_string(_value), do: nil

  defp bounded_string(value, max_length) do
    case normalize_string(value) do
      nil -> nil
      value -> String.slice(value, 0, max_length)
    end
  end

  defp value_for(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp has_key?(attrs, key), do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit >= 0, do: limit(query, ^limit)
  defp maybe_limit(query, _limit), do: query

  defp default(key), do: Application.get_env(:pinchflat, :channel_discovery, []) |> Keyword.get(key)
  defp bounded_integer(value, fallback) when is_integer(value), do: max(value, 0) |> min(fallback)
  defp bounded_integer(_value, fallback), do: fallback
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp safe_reason(reason)
       when reason in [
              :generator_failed,
              :featured_unavailable,
              :runner_failed,
              :malformed_response,
              :persistence_failed
            ],
       do: reason

  defp safe_reason(_reason), do: :generator_failed
end
