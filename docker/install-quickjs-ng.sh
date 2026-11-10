#!/bin/sh
# Installs the pinned QuickJS-NG runtime that yt-dlp uses to solve YouTube
# JavaScript challenges, plus the upstream MIT license notice.
#
# The version, assets and checksums are pinned. A failed download, a checksum
# mismatch or an unsupported target aborts the image build.
set -eu

QUICKJS_NG_VERSION="0.18.0"
DOWNLOAD_PREFIX="${QUICKJS_NG_DOWNLOAD_PREFIX:-https://github.com/quickjs-ng/quickjs/releases/download/v${QUICKJS_NG_VERSION}}"
LICENSE_URL="${QUICKJS_NG_LICENSE_URL:-https://raw.githubusercontent.com/quickjs-ng/quickjs/v${QUICKJS_NG_VERSION}/LICENSE}"
LICENSE_SHA256="96f73f9d2a16c21a36b418f06073be26e7d6d5e7c1bc99756b21a4f2c74ef171"
DESTDIR="${QUICKJS_NG_DESTDIR:-}"

target_platform="${TARGETPLATFORM:-}"

if [ -z "$target_platform" ]; then
  case "$(uname -m)" in
    x86_64 | amd64) target_platform="linux/amd64" ;;
    aarch64 | arm64) target_platform="linux/arm64" ;;
    *)
      echo "Unsupported host architecture for QuickJS-NG ${QUICKJS_NG_VERSION}: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

case "$target_platform" in
  "linux/amd64")
    asset="qjs-linux-x86_64"
    sha256="85ded23b9fabe8c1644fc40a8d2bbdd71157affcbd807359c618cc717ee24d7d"
    ;;
  "linux/arm64")
    asset="qjs-linux-aarch64"
    sha256="2c005c7171424a598d31c53c8dc4a0ae2e4958eb6fbb37908c885a307c78187c"
    ;;
  *)
    echo "Unsupported platform for QuickJS-NG ${QUICKJS_NG_VERSION}: ${target_platform}" >&2
    exit 1
    ;;
esac

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT HUP INT TERM

if ! curl -4 -fsSL --retry 5 --retry-all-errors "${DOWNLOAD_PREFIX}/${asset}" -o "${workdir}/qjs"; then
  echo "Failed to download QuickJS-NG ${QUICKJS_NG_VERSION} (${asset})" >&2
  exit 1
fi

if ! printf '%s  %s\n' "$sha256" "${workdir}/qjs" | sha256sum -c -; then
  echo "QuickJS-NG ${QUICKJS_NG_VERSION} checksum verification failed for ${asset}" >&2
  exit 1
fi

if ! curl -4 -fsSL --retry 5 --retry-all-errors "$LICENSE_URL" -o "${workdir}/LICENSE"; then
  echo "Failed to download the QuickJS-NG ${QUICKJS_NG_VERSION} LICENSE" >&2
  exit 1
fi

if ! printf '%s  %s\n' "$LICENSE_SHA256" "${workdir}/LICENSE" | sha256sum -c -; then
  echo "QuickJS-NG ${QUICKJS_NG_VERSION} LICENSE checksum verification failed" >&2
  exit 1
fi

install -d -m 0755 "${DESTDIR}/usr/local/bin" "${DESTDIR}/usr/share/licenses/quickjs-ng"
install -m 0755 "${workdir}/qjs" "${DESTDIR}/usr/local/bin/qjs"
install -m 0644 "${workdir}/LICENSE" "${DESTDIR}/usr/share/licenses/quickjs-ng/LICENSE"

"${DESTDIR}/usr/local/bin/qjs" --version
