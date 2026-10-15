defmodule Pinchflat.Sources.DirectoryMoveTest do
  use Pinchflat.DataCase
  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures
  alias Pinchflat.Sources
  alias Pinchflat.Sources.DirectoryMove

  defmodule SlowFile do
    def lstat(path) do
      Process.sleep(100)
      File.lstat(path)
    end

    def ls(path), do: File.ls(path)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "owned-safe-move-#{System.unique_integer([:positive])}")
    old = Path.join(base, "Old")
    new = Path.join(base, "New")
    File.mkdir_p!(old)
    File.write!(Path.join(old, "one.txt"), "one")
    extras = Application.fetch_env!(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, Path.join(base, "extras"))
    original = Application.fetch_env!(:pinchflat, :media_directory)
    Application.put_env(:pinchflat, :media_directory, base)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, extras)
      Application.put_env(:pinchflat, :media_directory, original)
      File.rm_rf!(base)
    end)

    %{base: base, old: old, new: new}
  end

  test "regular and empty directories move without overwriting", %{old: old, new: new} do
    File.mkdir_p!(Path.join(old, "empty"))
    assert {:ok, plan} = DirectoryMove.preview(old, new)
    assert plan.file_count == 1
    assert {:ok, :done} = DirectoryMove.with_moves(plan, fn -> {:ok, :done} end)
    assert File.read!(Path.join(new, "one.txt")) == "one"
    assert File.dir?(Path.join(new, "empty"))
    refute File.exists?(old)
  end

  test "symlinked files, directories, ancestors and cycles are refused", %{old: old, new: new, base: base} do
    for target <- [Path.join(old, "one.txt"), old, base] do
      link = Path.join(old, "link")
      File.ln_s!(target, link)
      assert {:error, :symlink} = DirectoryMove.preview(old, new)
      File.rm!(link)
    end

    File.ln_s!(old, new)
    assert {:error, :symlink} = DirectoryMove.preview(old, Path.join(new, "child"))
  end

  test "entry, depth, missing-root and slow-storage limits fail safely", %{old: old, new: new} do
    assert {:error, :entry_limit} = DirectoryMove.preview(old, new, entry_limit: 1)
    File.mkdir_p!(Path.join([old, "a", "b"]))
    assert {:error, :depth_limit} = DirectoryMove.preview(old, new, depth_limit: 1)
    assert {:error, :scan_timeout} = DirectoryMove.preview(old, new, filesystem: SlowFile, timeout: 10)
    assert {:error, :enoent} = DirectoryMove.preview(old <> "missing", new)
    assert {:error, :nested_destination} = DirectoryMove.preview(old, Path.join(old, "child"))
    assert File.read!(Path.join(old, "one.txt")) == "one"
  end

  test "conflicts and late target creation preserve all bytes", %{old: old, new: new} do
    assert {:ok, plan} = DirectoryMove.preview(old, new)
    File.mkdir_p!(new)
    File.write!(Path.join(new, "one.txt"), "existing")
    assert {:error, :eexist} = DirectoryMove.with_moves(plan, fn -> flunk("must not persist") end)
    assert File.read!(Path.join(old, "one.txt")) == "one"
    assert File.read!(Path.join(new, "one.txt")) == "existing"
  end

  test "callback rejection and raised failure restore moved files", %{old: old, new: new} do
    assert {:ok, plan} = DirectoryMove.preview(old, new)
    assert {:error, :db_rejected} = DirectoryMove.with_moves(plan, fn -> {:error, :db_rejected} end)
    assert File.read!(Path.join(old, "one.txt")) == "one"
    refute File.exists?(Path.join(new, "one.txt"))

    assert_raise RuntimeError, "injected failure", fn ->
      DirectoryMove.with_moves(plan, fn -> raise "injected failure" end)
    end

    assert File.read!(Path.join(old, "one.txt")) == "one"
  end

  test "shared artwork/subtitle ownership blocks context updates before moving", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    other = source_fixture(%{poster_filepath: Path.join(old, "one.txt")})
    assert {:error, cs} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    assert cs.errors[:download_subdirectory]
    other |> Ecto.Changeset.change(poster_filepath: nil) |> Repo.update!()
    media_item_fixture(%{source_id: other.id, subtitle_filepaths: [["en", Path.join(old, "one.txt")]]})
    assert {:error, _} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    assert Repo.reload!(source).series_directory == old
    assert File.read!(Path.join(old, "one.txt")) == "one"
    refute File.exists?(new)
  end

  test "hard kill before database commit retains originals and boot recovery removes links", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    {:ok, plan} = DirectoryMove.preview(old, new)
    parent = self()

    worker =
      spawn(fn ->
        DirectoryMove.with_moves(
          plan,
          fn ->
            send(parent, :linked)

            receive do
              :never -> {:ok, :done}
            end
          end,
          source_id: source.id
        )
      end)

    assert_receive :linked
    assert File.read!(Path.join(old, "one.txt")) == "one"
    assert File.read!(Path.join(new, "one.txt")) == "one"
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}
    assert :ok == DirectoryMove.recover!() |> List.first()
    assert File.read!(Path.join(old, "one.txt")) == "one"
    refute File.exists?(new)
    assert Repo.reload!(source).series_directory == old
  end

  test "recovery after committed database change completes cleanup", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    {:ok, plan} = DirectoryMove.preview(old, new)
    parent = self()

    worker =
      spawn(fn ->
        DirectoryMove.with_moves(
          plan,
          fn ->
            send(parent, :linked)

            receive do
              :never -> {:ok, :done}
            end
          end,
          source_id: source.id
        )
      end)

    assert_receive :linked
    Repo.update!(Ecto.Changeset.change(source, series_directory: new))
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}
    DirectoryMove.recover!()
    refute File.exists?(old)
    assert File.read!(Path.join(new, "one.txt")) == "one"
  end

  test "rollback attempts every link and retains journal when ownership changes", %{old: old, new: new, base: base} do
    File.write!(Path.join(old, "two.txt"), "two")
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    {:ok, plan} = DirectoryMove.preview(old, new)

    assert {:error, :rejected} =
             DirectoryMove.with_moves(
               plan,
               fn ->
                 File.rm!(Path.join(new, "one.txt"))
                 File.write!(Path.join(new, "one.txt"), "foreign bytes")
                 {:error, :rejected}
               end,
               source_id: source.id
             )

    assert File.read!(Path.join(old, "one.txt")) == "one"
    assert File.read!(Path.join(old, "two.txt")) == "two"
    assert File.read!(Path.join(new, "one.txt")) == "foreign bytes"
    refute File.exists?(Path.join(new, "two.txt"))
    assert [_] = Path.wildcard(Path.join([base, "extras", "directory-moves", "*.journal"]))

    assert {:error, :recovery_required} =
             DirectoryMove.with_moves(plan, fn -> flunk("blocked") end, source_id: source.id)

    assert_raise RuntimeError, ~r/recovery incomplete/, fn -> DirectoryMove.recover!() end
  end

  test "missing tracked files refuse a move without changing paths", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    item = media_item_fixture(%{source_id: source.id, media_filepath: Path.join(old, "missing.mp4")})
    assert {:error, cs} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    assert cs.errors[:download_subdirectory]
    assert Repo.reload!(item).media_filepath == Path.join(old, "missing.mp4")
    assert Repo.reload!(source).series_directory == old
    refute File.exists?(new)
  end

  test "internal metadata paths and subtitles follow a successful move", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    path = Path.join(old, "one.txt")
    item = media_item_fixture(%{source_id: source.id, media_filepath: path, subtitle_filepaths: [["en", path, path]]})
    sm = Repo.insert!(%Pinchflat.Metadata.SourceMetadata{source_id: source.id, metadata_filepath: path})

    mm =
      Repo.insert!(%Pinchflat.Metadata.MediaMetadata{
        media_item_id: item.id,
        metadata_filepath: path,
        thumbnail_filepath: path
      })

    assert {:ok, _} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    expected = Path.join(new, "one.txt")
    assert Repo.reload!(sm).metadata_filepath == expected
    assert Repo.reload!(mm).metadata_filepath == expected
    assert Repo.reload!(item).subtitle_filepaths == [["en", expected, expected]]
    assert File.read!(expected) == "one"
    refute File.exists?(old)
  end

  test "direct executing metadata jobs and destination ownership block moves", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    {:ok, job} = Oban.insert(Pinchflat.Metadata.SourceMetadataStorageWorker.new(%{id: source.id}))
    Repo.update!(Ecto.Changeset.change(job, state: "executing", attempt: 1))
    assert {:error, cs} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    assert cs.errors[:download_subdirectory]
    Repo.delete!(Repo.reload!(job))
    source_fixture(%{series_directory: new})
    assert {:error, _} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    assert File.read!(Path.join(old, "one.txt")) == "one"
    refute File.exists?(new)
  end

  test "shared internal metadata is not physically moved", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    other = source_fixture()
    Repo.insert!(%Pinchflat.Metadata.SourceMetadata{source_id: other.id, metadata_filepath: Path.join(old, "one.txt")})
    assert {:error, _} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
    assert File.read!(Path.join(old, "one.txt")) == "one"
    refute File.exists?(new)
  end

  test "configured internal storage roots are not relocated by a source move", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})
    previous = Application.fetch_env!(:pinchflat, :metadata_directory)
    Application.put_env(:pinchflat, :metadata_directory, Path.join(old, "internal"))

    try do
      assert {:error, cs} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
      assert cs.action == :update
      assert cs.errors[:download_subdirectory]
      refute File.exists?(new)
      assert File.read!(Path.join(old, "one.txt")) == "one"
    after
      Application.put_env(:pinchflat, :metadata_directory, previous)
    end
  end

  test "combining-character folders preserve every shared scalar ownership model", %{old: old, new: new} do
    relative = "Old/e\u0301"
    directory = Path.join(old, "e\u0301")
    File.mkdir_p!(directory)
    path = Path.join(directory, "shared.txt")
    File.write!(path, "owned combining bytes")
    source = source_fixture(%{series_directory: directory, download_subdirectory: relative})
    other = source_fixture()
    item = media_item_fixture(%{source_id: other.id, media_filepath: nil})

    records = [
      {other, %{poster_filepath: path}},
      {item, %{media_filepath: path}},
      {%Pinchflat.Metadata.SourceMetadata{source_id: other.id}, %{metadata_filepath: path}},
      {%Pinchflat.Metadata.MediaMetadata{media_item_id: item.id}, %{metadata_filepath: path, thumbnail_filepath: path}}
    ]

    for {record, attrs} <- records do
      changed =
        if Ecto.get_meta(record, :state) == :built do
          record |> Ecto.Changeset.change(attrs) |> Repo.insert!()
        else
          record |> Ecto.Changeset.change(attrs) |> Repo.update!()
        end

      assert {:error, cs} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
      assert cs.errors[:download_subdirectory]
      assert File.read!(path) == "owned combining bytes"
      refute File.exists?(new)

      if Ecto.get_meta(record, :state) == :built do
        Repo.delete!(changed)
      else
        changed |> Ecto.Changeset.change(Map.new(attrs, fn {key, _} -> {key, nil} end)) |> Repo.update!()
      end
    end
  end

  @tag :migration_schema
  test "late database rejection restores source rows and physical files", %{old: old, new: new} do
    source = source_fixture(%{series_directory: old, download_subdirectory: "Old"})

    if Pinchflat.Database.postgres?() do
      Repo.query!(
        "CREATE FUNCTION owned_move_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'owned move fault'; END; $$"
      )

      Repo.query!(
        "CREATE TRIGGER owned_move_fault BEFORE UPDATE ON sources FOR EACH ROW WHEN (OLD.id = #{source.id}) EXECUTE FUNCTION owned_move_fault()"
      )
    else
      Repo.query!(
        "CREATE TRIGGER owned_move_fault BEFORE UPDATE ON sources WHEN OLD.id = #{source.id} BEGIN SELECT RAISE(ABORT, 'owned move fault'); END"
      )
    end

    try do
      assert {:error, _} = Sources.update_source(source, %{download_subdirectory: "New"}, run_post_commit_tasks: false)
      assert File.read!(Path.join(old, "one.txt")) == "one"
      refute File.exists?(Path.join(new, "one.txt"))
      assert Repo.reload!(source).series_directory == old
    after
      if Pinchflat.Database.postgres?() do
        Repo.query!("DROP TRIGGER owned_move_fault ON sources")
        Repo.query!("DROP FUNCTION owned_move_fault()")
      else
        Repo.query!("DROP TRIGGER owned_move_fault")
      end
    end
  end
end
