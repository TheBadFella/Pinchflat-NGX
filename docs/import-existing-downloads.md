# Import existing downloads

Open an existing source, pause it, wait for running jobs to finish, and choose **Import Downloads**. Enter a folder relative to the downloads mount and choose **Preview Import**. Check the matching files, then choose **Import Matching Files**.

The importer scans yt-dlp `.info.json` files and matches media by the same filename stem. Supported extensions are `.mp4`, `.mkv`, `.webm`, `.m4a`, `.mp3`, `.opus`, `.ogg`, `.flac`, `.wav`, `.aac`, `.mov`, `.avi`, and `.m4v`. It does not guess IDs from titles or filenames. Files without usable metadata need an info sidecar before they can be imported.

New items require metadata matching the source's channel, playlist, or video ID. Already indexed items can match their media ID within that source. Metadata must contain an ID, title, and valid upload date. Missing or ambiguous media files, mismatched sources, and paths already owned by another item are skipped. Existing downloaded records are left alone.

Imports record the existing paths and byte sizes, mark items downloaded, and protect them from automatic retention deletion. Files are not moved, rewritten, transcoded, or fetched from the network. Existing metadata sidecars are retained; thumbnail, subtitle, and NFO sidecars are not separately registered by this initial import flow. No download jobs are enqueued. You can unpause the source when you have reviewed the imported library and its normal download/retention settings.

Preview tokens expire after 15 minutes. Applying an import rescans the source and folder; changes invalidate the preview. Database changes are transactional, so an error does not leave a partial batch. Media and metadata must remain mounted and unchanged during import. The scan skips symlinks, is limited to 5,000 files, and accepts metadata up to 5 MB per sidecar. Choose smaller subfolders for larger libraries.

Database migration from an original Pinchflat installation remains separate. Use that route when you already have its database, rather than importing the same files as a new library.
