#!/usr/bin/env bash
# Build the GHW documentation site with zdoc (https://github.com/chy3xyz/zdoc).
#
# Usage:
#   bash scripts/build_docs.sh [output-dir] [url-prefix]
#
# Defaults: output-dir=site/public, url-prefix=/ghw/ (GitHub Pages project site).
# The prefix is passed straight to zdoc's --url-prefix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/site/public}"
URL_PREFIX="${2:-/ghw/}"
ZDOC_VERSION="v0.16.0"
TOOLS="$ROOT/.tools"

case "$(uname -sm)" in
  "Darwin arm64")  ZDOC_ASSET="aarch64-macos.zip" ;;
  "Linux x86_64")  ZDOC_ASSET="x86_64-linux-musl.tar.xz" ;;
  "Linux aarch64") ZDOC_ASSET="aarch64-linux-musl.tar.xz" ;;
  *) echo "unsupported platform: $(uname -sm)" >&2; exit 1 ;;
esac

mkdir -p "$TOOLS"
ZDOC_BIN="$TOOLS/zdoc"
if [ ! -x "$ZDOC_BIN" ] || ! "$ZDOC_BIN" version 2>/dev/null | grep -q "${ZDOC_VERSION#v}"; then
  echo "downloading zdoc $ZDOC_VERSION ($ZDOC_ASSET)..."
  rm -f "$TOOLS/zdoc"
  curl -fsSL "https://github.com/chy3xyz/zdoc/releases/download/$ZDOC_VERSION/$ZDOC_ASSET" -o "$TOOLS/$ZDOC_ASSET"
  # verify against the release checksum when sha256sum is available
  if command -v sha256sum >/dev/null 2>&1; then
    curl -fsSL "https://github.com/chy3xyz/zdoc/releases/download/$ZDOC_VERSION/SHA256SUMS" -o "$TOOLS/SHA256SUMS"
    (cd "$TOOLS" && grep " $ZDOC_ASSET\$" SHA256SUMS | sha256sum -c -)
  fi
  case "$ZDOC_ASSET" in
    *.zip) unzip -o -q "$TOOLS/$ZDOC_ASSET" -d "$TOOLS" ;;
    *.tar.xz) tar -xJf "$TOOLS/$ZDOC_ASSET" -C "$TOOLS" ;;
  esac
  chmod +x "$ZDOC_BIN"
fi

rm -rf "$OUT"
"$ZDOC_BIN" docs "$ROOT/site/docs" --output "$OUT" --title "GHW" --url-prefix "$URL_PREFIX"

echo "docs site written to $OUT (url prefix: $URL_PREFIX)"
