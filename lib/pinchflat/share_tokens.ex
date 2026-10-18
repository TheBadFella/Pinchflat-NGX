defmodule Pinchflat.ShareTokens do
  @moduledoc """
  Context module for managing scoped share intake credentials.

  ### Security and Lifetime
  - Secrets are generated using 32 cryptographically secure random bytes.
  - Raw secrets are never stored in the database or logs; only the SHA-256 digest is stored.
  - Tokens are strictly bound to a single media profile.
  - Tokens can be revoked at any time.
  - Expiry is optional; existing non-expiring credentials remain valid.

  ### Revocation Boundary
  Revocation takes effect immediately for all subsequent incoming requests. If an intake
  request was already validated and its download job committed to the Oban queue before
  revocation occurred, that existing job will complete under standard download worker
  policies. Revocation does not retroactively cancel in-flight jobs.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.ShareTokens.ShareToken

  @type token_with_secret :: {:ok, ShareToken.t(), String.t()}

  @doc """
  Lists all share tokens, ordered by most recently created first.
  Preloads the associated media profile.
  """
  def list_tokens do
    ShareToken
    |> order_by([t], desc: t.inserted_at)
    |> preload([:media_profile])
    |> Repo.all()
  end

  @doc """
  Gets a single share token by ID, preloading its media profile.
  Raises `Ecto.NoResultsError` if the record does not exist.
  """
  def get_token!(id) do
    ShareToken
    |> preload([:media_profile])
    |> Repo.get!(id)
  end

  @doc """
  Creates a new share token.

  Generates 32 random bytes from `:crypto.strong_rand_bytes/1`, hashes it with SHA-256,
  and stores the digest.

  Returns `{:ok, %ShareToken{}, raw_secret}` on success, or `{:error, %Ecto.Changeset{}}` on failure.
  """
  @spec create_token(map()) :: token_with_secret() | {:error, Ecto.Changeset.t()}
  def create_token(attrs) do
    raw_bytes = :crypto.strong_rand_bytes(32)
    secret = Base.url_encode64(raw_bytes, padding: false)
    digest = hash_secret(secret)

    attrs_with_digest =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("token_digest", digest)

    %ShareToken{}
    |> ShareToken.changeset(attrs_with_digest)
    |> Repo.insert()
    |> case do
      {:ok, token} ->
        token = Repo.preload(token, [:media_profile])
        {:ok, token, secret}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Revokes an active share token by setting `revoked_at`.
  """
  def revoke_token(%ShareToken{} = token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    token
    |> Ecto.Changeset.change(%{revoked_at: now})
    |> Repo.update()
  end

  def revoke_token(token_id) when is_integer(token_id) do
    token_id
    |> get_token!()
    |> revoke_token()
  end

  @doc """
  Permanently deletes a share token.
  """
  def delete_token(%ShareToken{} = token) do
    Repo.delete(token)
  end

  def delete_token(token_id) when is_integer(token_id) do
    token_id
    |> get_token!()
    |> delete_token()
  end

  @doc """
  Authenticates a raw token secret.

  Verifies the SHA-256 digest against the indexed token records, ensures the token
  is not revoked, and verifies that the bound media profile still exists.
  Updates `last_used_at` upon successful authentication.

  Returns `{:ok, %ShareToken{}}` or `{:error, reason}` where reason is:
  - `:invalid_token` — secret does not match any record
  - `:revoked` — token has been revoked
  - `:expired` — token has reached its expiry time
  - `:profile_deleted` — bound media profile has been removed
  """
  @spec authenticate(String.t()) ::
          {:ok, ShareToken.t()}
          | {:error, :invalid_token | :revoked | :expired | :profile_deleted}
  def authenticate(secret) when is_binary(secret) and byte_size(secret) > 0 do
    digest = hash_secret(secret)

    query =
      from(t in ShareToken,
        where: t.token_digest == ^digest,
        preload: [:media_profile]
      )

    case Repo.one(query) do
      %ShareToken{} = token ->
        if Plug.Crypto.secure_compare(token.token_digest, digest) do
          validate_token_state(token)
        else
          {:error, :invalid_token}
        end

      nil ->
        {:error, :invalid_token}
    end
  end

  def authenticate(_), do: {:error, :invalid_token}

  @doc """
  Re-validates that a token and its bound media profile remain active at the mutation boundary.
  """
  def validate_mutation_boundary(%ShareToken{id: id, media_profile_id: profile_id}) do
    case Repo.get(ShareToken, id) do
      %ShareToken{revoked_at: nil} = current ->
        cond do
          not ShareToken.active?(current) -> {:error, :expired}
          current.media_profile_id != profile_id -> {:error, :invalid_token}
          is_nil(Repo.get(MediaProfile, profile_id)) -> {:error, :profile_deleted}
          true -> :ok
        end

      %ShareToken{} ->
        {:error, :revoked}

      nil ->
        {:error, :invalid_token}
    end
  end

  defp validate_token_state(%ShareToken{revoked_at: revoked_at}) when not is_nil(revoked_at) do
    {:error, :revoked}
  end

  defp validate_token_state(%ShareToken{media_profile: nil}) do
    {:error, :profile_deleted}
  end

  defp validate_token_state(%ShareToken{} = token) do
    if ShareToken.active?(token), do: record_usage(token), else: {:error, :expired}
  end

  defp record_usage(token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Update last_used_at
    token
    |> Ecto.Changeset.change(%{last_used_at: now})
    |> Repo.update()
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
  end
end
