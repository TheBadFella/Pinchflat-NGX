defmodule Pinchflat.Sources.CustomPosterTest do
  use Pinchflat.DataCase, async: false

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Sources.CustomPoster

  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
  @webp Base.decode64!("UklGRiIAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAUAmJaQAA3AA/vuUAAA=")

  setup do
    previous_resolver = Application.get_env(:pinchflat, :source_poster_dns_resolver, :not_configured)

    Application.put_env(:pinchflat, :source_poster_dns_resolver, fn host ->
      if host == "127.0.0.1" do
        {:ok, [{127, 0, 0, 1}]}
      else
        {:ok, [{93, 184, 216, 34}]}
      end
    end)

    on_exit(fn ->
      case previous_resolver do
        :not_configured -> Application.delete_env(:pinchflat, :source_poster_dns_resolver)
        resolver -> Application.put_env(:pinchflat, :source_poster_dns_resolver, resolver)
      end
    end)

    :ok
  end

  describe "set_from_upload/2" do
    test "accepts valid JPEG, PNG, and WebP images" do
      valid_images = [
        {File.read!(thumbnail_filepath_fixture()), "jpg", "image/jpeg"},
        {@png, "png", "image/png"},
        {@webp, "webp", "image/webp"}
      ]

      for {contents, extension, content_type} <- valid_images do
        source = source_fixture()

        assert {:ok, saved_source} =
                 CustomPoster.set_from_upload(source, upload_for(contents, extension, content_type))

        assert saved_source.custom_poster_filename =~ ~r/^custom-poster-[0-9a-f-]+\.#{extension}$/
        assert File.read!(CustomPoster.filepath(saved_source)) == contents
      end
    end

    test "rejects a body that is not a supported image" do
      source = source_fixture()

      assert {:error, :invalid_image} =
               CustomPoster.set_from_upload(source, upload_for("not an image", "png", "image/png"))

      assert is_nil(Repo.reload!(source).custom_poster_filename)
    end

    test "rejects an upload larger than 10 MB" do
      source = source_fixture()
      contents = :binary.copy(<<0>>, CustomPoster.max_size() + 1)

      assert {:error, :too_large} =
               CustomPoster.set_from_upload(source, upload_for(contents, "jpg", "image/jpeg"))

      assert is_nil(Repo.reload!(source).custom_poster_filename)
    end
  end

  describe "set_from_url/2" do
    test "fetches and validates a poster through the HTTP abstraction" do
      source = source_fixture()

      expect(HTTPClientMock, :get, fn "https://example.com/poster.png", [], opts ->
        assert opts == [receive_timeout: 10_000, request_timeout: 30_000]
        {:ok, @png}
      end)

      assert {:ok, saved_source} = CustomPoster.set_from_url(source, "https://example.com/poster.png")
      assert saved_source.custom_poster_filename =~ ~r/\.png$/
      assert File.read!(CustomPoster.filepath(saved_source)) == @png
    end

    test "preserves the HTTP timeout error" do
      source = source_fixture()
      expect(HTTPClientMock, :get, fn _url, [], _opts -> {:error, "request timed out"} end)

      assert {:error, "request timed out"} = CustomPoster.set_from_url(source, "https://example.com/poster.png")
    end

    test "rejects an oversized response" do
      source = source_fixture()
      contents = :binary.copy(<<0>>, CustomPoster.max_size() + 1)
      expect(HTTPClientMock, :get, fn _url, [], _opts -> {:ok, contents} end)

      assert {:error, :too_large} = CustomPoster.set_from_url(source, "https://example.com/poster.png")
    end

    test "does not follow redirects" do
      source = source_fixture()

      expect(HTTPClientMock, :get, fn _url, [], _opts ->
        {:error, "HTTP request failed with status code 302"}
      end)

      assert {:error, "HTTP request failed with status code 302"} =
               CustomPoster.set_from_url(source, "https://example.com/poster.png")
    end

    test "rejects private addresses before making a request" do
      source = source_fixture()
      expect(HTTPClientMock, :get, 0, fn _url, [], _opts -> {:ok, @png} end)

      assert {:error, :unsafe_url} = CustomPoster.set_from_url(source, "http://127.0.0.1/poster.png")
    end

    test "rejects an invalid image response" do
      source = source_fixture()
      expect(HTTPClientMock, :get, fn _url, [], _opts -> {:ok, "not an image"} end)

      assert {:error, :invalid_image} = CustomPoster.set_from_url(source, "https://example.com/poster.png")
    end

    test "rejects non-HTTP(S) URLs" do
      source = source_fixture()
      expect(HTTPClientMock, :get, 0, fn _url, [], _opts -> {:ok, @png} end)

      assert {:error, :invalid_url} = CustomPoster.set_from_url(source, "file:///etc/passwd")
    end
  end

  describe "replacement and removal" do
    test "removes the old file only after a successful replacement" do
      source = source_fixture()

      {:ok, first_source} =
        CustomPoster.set_from_upload(source, upload_for(File.read!(thumbnail_filepath_fixture()), "jpg", "image/jpeg"))

      old_filename = first_source.custom_poster_filename
      old_filepath = CustomPoster.filepath(first_source)

      {:ok, second_source} = CustomPoster.set_from_upload(first_source, upload_for(@png, "png", "image/png"))

      assert second_source.custom_poster_filename != old_filename
      refute File.exists?(old_filepath)
      assert File.exists?(CustomPoster.filepath(second_source))
    end

    test "retains the old file when a replacement fails validation" do
      source = source_fixture()

      {:ok, saved_source} =
        CustomPoster.set_from_upload(source, upload_for(File.read!(thumbnail_filepath_fixture()), "jpg", "image/jpeg"))

      old_filename = saved_source.custom_poster_filename
      old_filepath = CustomPoster.filepath(saved_source)
      expect(HTTPClientMock, :get, fn _url, [], _opts -> {:ok, "not an image"} end)

      assert {:error, :invalid_image} = CustomPoster.set_from_url(saved_source, "https://example.com/bad.png")
      assert Repo.reload!(source).custom_poster_filename == old_filename
      assert File.exists?(old_filepath)
    end

    test "removes the custom poster and falls back to fetched metadata artwork" do
      source = source_with_metadata_attachments()
      metadata = Repo.preload(source, :metadata).metadata

      {:ok, saved_source} = CustomPoster.set_from_upload(source, upload_for(@png, "png", "image/png"))
      custom_filepath = CustomPoster.filepath(saved_source)

      assert Sources.image_filepath(saved_source, :poster) == custom_filepath

      assert {:ok, removed_source} = CustomPoster.remove(saved_source)
      refute File.exists?(custom_filepath)
      assert is_nil(removed_source.custom_poster_filename)
      assert Sources.image_filepath(removed_source, :poster) == metadata.poster_filepath
    end

    test "deletes the custom file when the source is deleted" do
      source = source_fixture()
      {:ok, saved_source} = CustomPoster.set_from_upload(source, upload_for(@png, "png", "image/png"))
      custom_filepath = CustomPoster.filepath(saved_source)

      assert {:ok, _deleted_source} = Sources.delete_source(saved_source, delete_files: false)
      refute File.exists?(custom_filepath)
      assert Repo.get(Pinchflat.Sources.Source, source.id) == nil
    end
  end

  defp upload_for(contents, extension, content_type) do
    path = Path.join(System.tmp_dir!(), "pinchflat-custom-poster-upload-#{Ecto.UUID.generate()}.#{extension}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: "poster.#{extension}", content_type: content_type}
  end
end
