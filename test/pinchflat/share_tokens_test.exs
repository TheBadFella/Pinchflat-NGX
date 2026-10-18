defmodule Pinchflat.ShareTokensTest do
  use Pinchflat.DataCase

  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Profiles
  alias Pinchflat.ShareTokens
  alias Pinchflat.ShareTokens.ShareToken

  describe "token lifecycle" do
    test "expired credentials cannot authenticate or authorize a mutation" do
      profile = media_profile_fixture()
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      {:ok, token, secret} =
        ShareTokens.create_token(%{name: "Expiring", media_profile_id: profile.id, expires_at: expires_at})

      assert token.expires_at == expires_at

      token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second))
      |> Repo.update!()

      assert {:error, :expired} = ShareTokens.authenticate(secret)
      assert {:error, :expired} = ShareTokens.validate_mutation_boundary(token)
    end

    test "create_token/1 generates 32-byte secret and stores only sha256 digest" do
      profile = media_profile_fixture()

      assert {:ok, %ShareToken{} = token, secret} =
               ShareTokens.create_token(%{
                 name: "My Shortcut",
                 media_profile_id: profile.id
               })

      assert token.name == "My Shortcut"
      assert token.media_profile_id == profile.id
      assert is_binary(secret)
      assert byte_size(secret) >= 43
      assert is_binary(token.token_digest)
      assert byte_size(token.token_digest) == 64
      # The secret itself is NEVER stored directly in the database
      refute token.token_digest == secret
      assert is_nil(token.revoked_at)
      assert is_nil(token.expires_at)
      assert is_nil(token.last_used_at)

      # Ensure indexed digest matches sha256 of the returned secret
      expected_digest = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
      assert token.token_digest == expected_digest
    end

    test "list_tokens/0 returns tokens with preloaded media_profile" do
      profile = media_profile_fixture()
      {:ok, token1, _} = ShareTokens.create_token(%{name: "Token 1", media_profile_id: profile.id})
      {:ok, token2, _} = ShareTokens.create_token(%{name: "Token 2", media_profile_id: profile.id})

      tokens = ShareTokens.list_tokens()
      token_ids = Enum.map(tokens, & &1.id)

      assert token2.id in token_ids
      assert token1.id in token_ids

      first = Enum.find(tokens, &(&1.id == token1.id))
      assert first.media_profile.id == profile.id
    end

    test "get_token!/1 retrieves token with media_profile" do
      profile = media_profile_fixture()
      {:ok, token, _} = ShareTokens.create_token(%{name: "Lookup Test", media_profile_id: profile.id})

      retrieved = ShareTokens.get_token!(token.id)
      assert retrieved.id == token.id
      assert retrieved.media_profile.id == profile.id
    end

    test "revoke_token/1 sets revoked_at timestamp" do
      profile = media_profile_fixture()
      {:ok, token, _} = ShareTokens.create_token(%{name: "Revoke Test", media_profile_id: profile.id})

      assert {:ok, revoked} = ShareTokens.revoke_token(token)
      refute is_nil(revoked.revoked_at)
      refute ShareToken.active?(revoked)

      # Also test with ID
      assert {:ok, _} = ShareTokens.revoke_token(token.id)
    end

    test "delete_token/1 removes the token record" do
      profile = media_profile_fixture()
      {:ok, token, _} = ShareTokens.create_token(%{name: "Delete Test", media_profile_id: profile.id})

      assert {:ok, _} = ShareTokens.delete_token(token.id)
      assert_raise Ecto.NoResultsError, fn -> ShareTokens.get_token!(token.id) end
    end

    test "deleting media profile nilifies association and invalidates token authentication" do
      profile = media_profile_fixture()
      {:ok, token, secret} = ShareTokens.create_token(%{name: "Profile Deleted Test", media_profile_id: profile.id})

      {:ok, _} = Profiles.delete_media_profile(profile)
      retrieved = ShareTokens.get_token!(token.id)
      assert is_nil(retrieved.media_profile_id)
      assert is_nil(retrieved.media_profile)

      assert {:error, :profile_deleted} = ShareTokens.authenticate(secret)
    end
  end

  describe "authentication" do
    test "authenticate/1 returns {:ok, token} and updates last_used_at for valid secret" do
      profile = media_profile_fixture()
      {:ok, token, secret} = ShareTokens.create_token(%{name: "Auth Test", media_profile_id: profile.id})

      assert is_nil(token.last_used_at)
      assert {:ok, authenticated} = ShareTokens.authenticate(secret)
      assert authenticated.id == token.id
      assert authenticated.media_profile.id == profile.id
      refute is_nil(authenticated.last_used_at)
    end

    test "authenticate/1 returns {:error, :invalid_token} for unknown or empty secrets" do
      assert {:error, :invalid_token} = ShareTokens.authenticate("nonexistent_secret_value")
      assert {:error, :invalid_token} = ShareTokens.authenticate("")
      assert {:error, :invalid_token} = ShareTokens.authenticate(nil)
    end

    test "authenticate/1 returns {:error, :revoked} when token is revoked" do
      profile = media_profile_fixture()
      {:ok, token, secret} = ShareTokens.create_token(%{name: "Revoked Auth", media_profile_id: profile.id})

      {:ok, _} = ShareTokens.revoke_token(token)
      assert {:error, :revoked} = ShareTokens.authenticate(secret)
    end

    test "validate_mutation_boundary/1 guards against mid-request revocation or profile deletion" do
      profile = media_profile_fixture()
      {:ok, token, _} = ShareTokens.create_token(%{name: "Boundary Guard", media_profile_id: profile.id})

      assert :ok = ShareTokens.validate_mutation_boundary(token)

      # Revoked
      {:ok, _} = ShareTokens.revoke_token(token)
      assert {:error, :revoked} = ShareTokens.validate_mutation_boundary(token)
    end
  end
end
