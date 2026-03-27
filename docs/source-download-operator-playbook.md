# Source Download Operator Playbook

Use these commands from the project root on a Docker deployment to inspect source state, pending media, and download activity.

## 1. Inspect recent sources

```bash
docker compose exec phx mix run -e "alias Pinchflat.{Repo,Sources.Source}; import Ecto.Query; Repo.all(from s in Source, order_by: [desc: s.id], limit: 10, select: %{id: s.id, custom_name: s.custom_name, collection_type: s.collection_type, selection_mode: s.selection_mode, download_media: s.download_media, enabled: s.enabled, last_indexed_at: s.last_indexed_at}) |> IO.inspect(limit: :infinity)"
```

## 2. Inspect one source directly

Replace `SOURCE_ID` with the source you are debugging.

```bash
docker compose exec phx mix run -e "alias Pinchflat.{Repo,Sources.Source}; s=Repo.get!(Source, SOURCE_ID); IO.inspect(%{id: s.id, custom_name: s.custom_name, collection_type: s.collection_type, selection_mode: s.selection_mode, download_media: s.download_media, enabled: s.enabled, last_indexed_at: s.last_indexed_at})"
```

## 3. Inspect pending media items for a source

```bash
docker compose exec phx mix run -e "alias Pinchflat.{Repo,Media.MediaItem}; import Ecto.Query; Repo.all(from m in MediaItem, where: m.source_id == ^SOURCE_ID, order_by: [asc: m.playlist_index, desc: m.uploaded_at], limit: 20, select: %{id: m.id, title: m.title, media_filepath: m.media_filepath, prevent_download: m.prevent_download, last_error: m.last_error, uploaded_at: m.uploaded_at}) |> IO.inspect(limit: :infinity)"
```

## 4. Inspect active and queued download jobs for a source

```bash
docker compose exec phx mix run -e "alias Pinchflat.{Repo,Tasks.Task}; import Ecto.Query; Repo.all(from t in Task, join: j in assoc(t, :job), join: mi in assoc(t, :media_item), where: mi.source_id == ^SOURCE_ID, where: fragment(\"? LIKE ?\", j.worker, ^\"%.MediaDownloadWorker\"), where: j.state in ^[\"available\", \"scheduled\", \"retryable\", \"executing\"], select: %{task_id: t.id, media_item_id: t.media_item_id, job_id: t.job_id, state: j.state, inserted_at: t.inserted_at}) |> IO.inspect(limit: :infinity)"
```

## 5. Tail useful logs

These are the structured log markers added for this release:

- `source_created`
- `pending_download_enqueue`
- `pending_download_enqueue_skipped`
- `indexing_completed`
- `media_download_skipped`

```bash
docker compose logs phx --since=2h | grep -E "source_created|pending_download_enqueue|indexing_completed|media_download_skipped"
```

## 6. What the skip reasons mean

- `source_downloads_disabled`: the source is disabled for downloading
- `item_prevented`: the media item has `prevent_download=true`
- `item_not_pending`: the item is already downloaded or otherwise not pending
- `format_or_profile_mismatch`: the source rules excluded it, such as cutoff date, shorts/livestream rules, duration limits, or title filtering
