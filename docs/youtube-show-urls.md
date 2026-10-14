# YouTube show URLs

Paste a YouTube show URL into the source URL field and use Automatic or Playlist as the source type. URLs in the form `https://www.youtube.com/show/VLPL...` are converted to `https://www.youtube.com/playlist?list=PL...` before inspection and saved in that form. Tracking query parameters are discarded.

The playlist is inspected through the existing yt-dlp path, so the source uses the full playlist rather than the smaller selection yt-dlp can return for a show landing page. The playlist's permissions, availability, and account restrictions still apply.

Enable Delay Automatic Download if you want to review episodes before downloading. Conversion does not change your download settings or select episodes automatically. Choosing Channel or Video for a show still produces the existing source-type mismatch error.

Only show links with an embedded `VLPL...` playlist ID are converted. Other show URL formats must use their playlist URL directly; the app does not scrape landing pages or guess an unrelated playlist.
