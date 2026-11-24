#!/bin/sh
# Installs ffmpeg and ffprobe from a pinned yt-dlp FFmpeg-Builds release.
#
# Usage: install-ffmpeg.sh DESTINATION_DIR
#
# The pin is a month-end autobuild: yt-dlp keeps those, but deletes daily builds
# after a few weeks, which would make older image builds fail. Asset names change
# with every build, so the script finds this platform's asset in the release's
# checksums.sha256 and verifies the download against it. A failed download, a
# checksum mismatch or an unsupported target aborts the image build.
set -eu

# renovate: datasource=github-releases depName=yt-dlp/FFmpeg-Builds
FFMPEG_BUILD="autobuild-2026-10-31-18-18"
DOWNLOAD_PREFIX="https://github.com/yt-dlp/FFmpeg-Builds/releases/download/${FFMPEG_BUILD}"
destination="${1:?Usage: install-ffmpeg.sh DESTINATION_DIR}"

target_platform="${TARGETPLATFORM:-}"

if [ -z "$target_platform" ]; then
  case "$(uname -m)" in
    x86_64 | amd64) target_platform="linux/amd64" ;;
    aarch64 | arm64) target_platform="linux/arm64" ;;
    *)
      echo "Unsupported host architecture for FFmpeg ${FFMPEG_BUILD}: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

case "$target_platform" in
  "linux/amd64") platform="linux64" ;;
  "linux/arm64") platform="linuxarm64" ;;
  *)
    echo "Unsupported platform for FFmpeg ${FFMPEG_BUILD}: ${target_platform}" >&2
    exit 1
    ;;
esac

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

if ! curl -4 -fsSL --retry 5 --retry-all-errors "${DOWNLOAD_PREFIX}/checksums.sha256" -o "${workdir}/checksums.sha256"; then
  echo "Failed to download the checksums for FFmpeg ${FFMPEG_BUILD}" >&2
  exit 1
fi

checksum_line="$(grep -E "^[0-9a-f]{64}  ffmpeg-N-[0-9]+-g[0-9a-f]+-${platform}-gpl\.tar\.xz$" "${workdir}/checksums.sha256" || true)"

if [ -z "$checksum_line" ] || [ "$(printf '%s\n' "$checksum_line" | wc -l)" -ne 1 ]; then
  echo "Expected one ${platform}-gpl asset in FFmpeg ${FFMPEG_BUILD}'s checksums.sha256" >&2
  exit 1
fi

asset="${checksum_line##* }"

if ! curl -4 -fsSL --retry 5 --retry-all-errors "${DOWNLOAD_PREFIX}/${asset}" -o "${workdir}/${asset}"; then
  echo "Failed to download FFmpeg ${FFMPEG_BUILD} (${asset})" >&2
  exit 1
fi

if ! (cd "$workdir" && printf '%s\n' "$checksum_line" | sha256sum -c -); then
  echo "FFmpeg ${FFMPEG_BUILD} checksum verification failed for ${asset}" >&2
  exit 1
fi

tar -xf "${workdir}/${asset}" --strip-components=2 --no-anchored -C "$destination" "ffmpeg" "ffprobe"

"${destination}/ffmpeg" -version | head -n 1
