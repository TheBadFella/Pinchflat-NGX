defmodule Pinchflat.Sources.DirectoryMove do
  @moduledoc "Bounded, symlink-refusing source directory planning and reversible file moves."

  require Logger

  def preview(old, new, opts \\ []) do
    task = Task.async(fn -> scan(Path.expand(old), Path.expand(new), opts) end)

    case Task.yield(task, Keyword.get(opts, :timeout, 2_000)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :scan_timeout}
    end
  end

  @doc "Retains originals until callback commits; journals links for interrupted-process recovery."
  def with_moves(plan, callback, opts \\ []) do
    source_id = Keyword.get(opts, :source_id)
    path = journal_path(source_id)

    with false <- File.exists?(path),
         :ok <- safe_ancestors(plan.new_directory, File),
         :ok <- verify_plan(plan),
         {:ok, journal} <- prepare_journal(plan, source_id),
         :ok <- persist_journal(path, journal) do
      apply_links(path, journal, callback)
    else
      true -> {:error, :recovery_required}
      error -> error
    end
  end

  @doc "Recover interrupted moves before any background jobs start; refuse ambiguous ownership."
  def recover! do
    for path <- Path.wildcard(Path.join(journal_directory(), "*.journal")) do
      journal = read_journal!(path)
      source = Pinchflat.Repo.get(Pinchflat.Sources.Source, journal.source_id)

      direction =
        case source do
          %{series_directory: directory} when directory == journal.plan.new_directory -> :committed
          %{series_directory: directory} when directory == journal.plan.old_directory -> :rejected
          _ -> raise "Source directory move needs manual recovery: #{path}"
        end

      case cleanup(path, journal, direction) do
        :ok -> :ok
        {:error, errors} -> raise "Source directory move recovery incomplete: #{path}: #{inspect(errors)}"
      end
    end
  end

  defp apply_links(path, journal, callback) do
    with :ok <- create_directories(journal.plan), :ok <- link_files(journal.files) do
      try do
        case callback.() do
          {:ok, _} = result ->
            # A cleanup failure retains the journal. The committed row already points at valid links.
            cleanup(path, journal, :committed)
            result

          error ->
            cleanup(path, journal, :rejected)
            error
        end
      rescue
        error ->
          recover_after_exception(path, journal)
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          recover_after_exception(path, journal)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      error ->
        cleanup(path, journal, :rejected)
        error
    end
  end

  defp recover_after_exception(path, %{source_id: nil} = journal), do: cleanup(path, journal, :rejected)

  defp recover_after_exception(path, journal) do
    case Pinchflat.Repo.get(Pinchflat.Sources.Source, journal.source_id) do
      %{series_directory: directory} when directory == journal.plan.old_directory -> cleanup(path, journal, :rejected)
      %{series_directory: directory} when directory == journal.plan.new_directory -> cleanup(path, journal, :committed)
      _ -> :recovery_required
    end
  rescue
    _ in [Postgrex.Error, Exqlite.Error, DBConnection.ConnectionError] -> :recovery_required
  end

  defp verify_plan(plan) do
    case preview(plan.old_directory, plan.new_directory) do
      {:ok, %{conflicts: [_ | _]}} ->
        {:error, :eexist}

      {:ok, current} ->
        if Enum.sort(current.files) == Enum.sort(plan.files) and
             Enum.sort(current.directories) == Enum.sort(plan.directories),
           do: :ok,
           else: {:error, :source_changed}

      error ->
        error
    end
  end

  defp prepare_journal(plan, source_id) do
    Enum.reduce_while(plan.files, {:ok, []}, fn {from, to}, {:ok, files} ->
      case File.lstat(from) do
        {:ok, %{type: :regular} = stat} ->
          {:cont, {:ok, [{from, to, identity(stat)} | files]}}

        _ ->
          {:halt, {:error, :source_changed}}
      end
    end)
    |> case do
      {:ok, files} ->
        created =
          plan.directories
          |> Enum.flat_map(fn directory ->
            missing_directories(Path.join(plan.new_directory, Path.relative_to(directory, plan.old_directory)))
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&String.length/1, :desc)

        {:ok, %{source_id: source_id, plan: plan, files: files, created_directories: created}}

      error ->
        error
    end
  end

  defp journal_directory do
    Path.join(Application.fetch_env!(:pinchflat, :extras_directory), "directory-moves")
  end

  defp journal_path(nil), do: Path.join(journal_directory(), "standalone-#{System.unique_integer([:positive])}.journal")
  defp journal_path(id), do: Path.join(journal_directory(), "source-#{id}.journal")

  defp persist_journal(path, journal) do
    temporary = path <> "." <> Ecto.UUID.generate() <> ".tmp"

    with {:ok, data} <- encode_journal(journal),
         :ok <- safe_ancestors(path, File),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         {:ok, file} <- :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- :file.write(file, data),
             :ok <- :file.sync(file) do
          File.ln(temporary, path)
        end
      after
        :file.close(file)
        File.rm(temporary)
      end
    end
  end

  defp encode_journal(journal) do
    data = %{
      source_id: journal.source_id,
      plan: Map.take(journal.plan, [:old_directory, :new_directory, :directories]),
      files: Enum.map(journal.files, fn {from, to, id} -> [from, to, Tuple.to_list(id)] end),
      created_directories: journal.created_directories
    }

    encoded = Jason.encode!(data)
    if byte_size(encoded) <= 16_777_216, do: {:ok, encoded}, else: {:error, :journal_limit}
  end

  defp read_journal!(path) do
    stat = File.lstat!(path)
    unless stat.type == :regular and stat.size <= 16_777_216, do: raise("Invalid directory move journal: #{path}")

    %{
      "source_id" => id,
      "plan" => %{"old_directory" => old, "new_directory" => new, "directories" => directories},
      "files" => files,
      "created_directories" => created
    } = path |> File.read!() |> Jason.decode!()

    %{
      source_id: id,
      plan: %{old_directory: old, new_directory: new, directories: directories},
      files: Enum.map(files, fn [from, to, [major, minor, inode]] -> {from, to, {major, minor, inode}} end),
      created_directories: created
    }
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp matches?(path, expected) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> identity(stat) == expected
      _ -> false
    end
  end

  defp link_files(files) do
    Enum.reduce_while(files, :ok, fn {from, to, expected}, :ok ->
      with :ok <- safe_ancestors(from, File),
           :ok <- safe_ancestors(to, File),
           true <- matches?(from, expected),
           :ok <- File.ln(from, to),
           :ok <- safe_ancestors(to, File),
           true <- matches?(to, expected) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :source_changed}}
        error -> {:halt, error}
      end
    end)
  end

  defp cleanup(path, journal, direction) do
    errors =
      Enum.reduce(journal.files, [], fn {from, to, expected}, errors ->
        {keep, remove} = if direction == :committed, do: {to, from}, else: {from, to}

        case remove_owned_link(keep, remove, expected) do
          :ok -> errors
          error -> [{remove, error} | errors]
        end
      end)

    if errors == [] do
      directories = if direction == :committed, do: journal.plan.directories, else: journal.created_directories
      Enum.each(directories, &File.rmdir/1)
      File.rm(path)
    else
      Logger.error("Directory move cleanup incomplete; recovery journal retained: #{path}")
      {:error, errors}
    end
  end

  defp missing_directories(path) do
    if File.exists?(path), do: [], else: [path | missing_directories(Path.dirname(path))]
  end

  defp remove_owned_link(keep, remove, expected) do
    with :ok <- safe_ancestors(keep, File), :ok <- safe_ancestors(remove, File) do
      cond do
        not matches?(keep, expected) -> {:error, :retained_file_changed}
        matches?(remove, expected) -> File.rm(remove)
        not File.exists?(remove) -> :ok
        true -> {:error, :cleanup_file_changed}
      end
    end
  end

  defp scan(old, new, opts) do
    fs = Keyword.get(opts, :filesystem, File)
    limit = Keyword.get(opts, :entry_limit, 10_000)
    depth = Keyword.get(opts, :depth_limit, 64)

    if String.starts_with?(new <> "/", old <> "/") do
      {:error, :nested_destination}
    else
      with :ok <- safe_ancestors(old, fs),
           :ok <- safe_ancestors(new, fs),
           {:ok, %{type: :directory}} <- fs.lstat(old),
           {:ok, result} <-
             walk([{old, new, 0}], %{files: [], directories: [], conflicts: [], entries: 0}, fs, limit, depth) do
        {:ok,
         Map.merge(result, %{
           old_directory: old,
           new_directory: new,
           old_directory_exists: true,
           new_directory_exists: File.exists?(new),
           file_count: length(result.files)
         })}
      else
        {:ok, _} -> {:error, :not_directory}
        error -> error
      end
    end
  end

  defp walk([], result, _fs, _limit, _depth), do: {:ok, result}
  defp walk(_pending, %{entries: count}, _fs, limit, _depth) when count >= limit, do: {:error, :entry_limit}
  defp walk([{_, _, level} | _], _result, _fs, _limit, depth) when level > depth, do: {:error, :depth_limit}

  defp walk([{from, to, level} | rest], result, fs, limit, depth) do
    with {:ok, stat} <- fs.lstat(from), :ok <- safe_ancestors(to, fs) do
      result = %{result | entries: result.entries + 1}

      case stat.type do
        :directory ->
          with {:ok, names} <- fs.ls(from), true <- length(names) + result.entries <= limit do
            children = Enum.map(names, &{Path.join(from, &1), Path.join(to, &1), level + 1})
            walk(children ++ rest, %{result | directories: [from | result.directories]}, fs, limit, depth)
          else
            false -> {:error, :entry_limit}
            error -> error
          end

        :regular ->
          conflicts = if File.exists?(to), do: [to | result.conflicts], else: result.conflicts
          walk(rest, %{result | files: [{from, to} | result.files], conflicts: conflicts}, fs, limit, depth)

        :symlink ->
          {:error, :symlink}

        _ ->
          {:error, :special_file}
      end
    end
  end

  defp safe_ancestors(path, fs) do
    parent = Path.dirname(path)

    result =
      case fs.lstat(path) do
        {:ok, %{type: :symlink}} -> {:error, :symlink}
        {:ok, _} -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end

    with :ok <- result do
      if parent == path, do: :ok, else: safe_ancestors(parent, fs)
    end
  end

  defp create_directories(plan) do
    plan.directories
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn directory, _ ->
      target = Path.join(plan.new_directory, Path.relative_to(directory, plan.old_directory))

      case File.mkdir_p(target) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
