defmodule PinchflatWeb.SourceFolderLoadingTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  setup do
    Settings.set(onboarding: false)
    :ok
  end

  test "new and edit reuse saved nested folders without inspecting the media filesystem", %{conn: conn} do
    saved = "Archive/日本語/Deep folder"
    source = source_fixture(%{download_subdirectory: saved})
    source_fixture(%{download_subdirectory: saved})
    root = Application.fetch_env!(:pinchflat, :media_directory)
    directory = Path.join(root, "Not-a-saved-folder")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rmdir(directory) end)

    for url <- [~p"/sources/new", ~p"/sources/#{source.id}/edit"] do
      response = conn |> recycle() |> get(url) |> html_response(200)
      assert response =~ "Pick existing source folder"
      assert response =~ "Choose from folders already under your media root"
      assert length(Regex.scan(~r/data-folder="Archive\/日本語\/Deep folder"/, response)) == 1
      refute response =~ "Not-a-saved-folder"
    end
  end

  test "an unavailable media root does not remove saved suggestions or the current value", %{conn: conn} do
    saved = "Unavailable/Nested/Folder"
    source = source_fixture(%{download_subdirectory: saved})
    original = Application.fetch_env!(:pinchflat, :media_directory)
    Application.put_env(:pinchflat, :media_directory, Path.join(original, "missing-mount"))
    on_exit(fn -> Application.put_env(:pinchflat, :media_directory, original) end)

    response = conn |> get(~p"/sources/#{source.id}/edit") |> html_response(200)
    assert response =~ ~s(value="#{saved}")
    assert response =~ ~s(data-folder="#{saved}")
  end

  test "manual nested folder input remains on a validation-error redisplay", %{conn: conn} do
    source = source_fixture()

    response =
      conn
      |> put(~p"/sources/#{source.id}", %{
        "source" => %{"media_profile_id" => "", "download_subdirectory" => "Manual/Nested/Folder"}
      })
      |> html_response(200)

    assert response =~ ~s(value="Manual/Nested/Folder")
    assert Repo.reload!(source).download_subdirectory == nil
  end

  test "suggestions are bounded without clearing a value outside the first page", %{conn: conn} do
    source = source_fixture(%{download_subdirectory: "ZZZ/Keep/This"})
    attrs = source |> Map.from_struct() |> Map.take(Pinchflat.Sources.Source.__schema__(:fields)) |> Map.delete(:id)

    entries =
      for i <- 1..201 do
        Map.merge(attrs, %{
          uuid: Ecto.UUID.generate(),
          collection_id: "folder-loading-#{i}",
          original_url: "https://www.youtube.com/channel/folder-loading-#{i}",
          download_subdirectory: "Saved/#{String.pad_leading(to_string(i), 3, "0")}"
        })
      end

    Repo.insert_all(Pinchflat.Sources.Source, entries)
    response = conn |> get(~p"/sources/#{source.id}/edit") |> html_response(200)
    assert length(Regex.scan(~r/data-folder="/, response)) == 200
    assert response =~ ~s(value="ZZZ/Keep/This")
    refute response =~ ~s(data-folder="Saved/201")
  end

  test "directory symlinks and cycles cannot expand saved folder suggestions", %{conn: conn} do
    source_fixture(%{download_subdirectory: "Saved/Only"})
    original = Application.fetch_env!(:pinchflat, :media_directory)
    root = Path.join(System.tmp_dir!(), "owned-folder-cycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.ln_s!(root, Path.join(root, "cycle"))
    File.ln_s!("/etc", Path.join(root, "outside"))
    Application.put_env(:pinchflat, :media_directory, root)

    on_exit(fn ->
      Application.put_env(:pinchflat, :media_directory, original)
      File.rm!(Path.join(root, "cycle"))
      File.rm!(Path.join(root, "outside"))
      File.rmdir!(root)
    end)

    response = conn |> get(~p"/sources/new") |> html_response(200)
    assert response =~ ~s(data-folder="Saved/Only")
    refute response =~ ~s(data-folder="cycle)
    refute response =~ ~s(data-folder="outside)
  end
end
