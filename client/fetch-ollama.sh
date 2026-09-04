#!/bin/bash
# Fetches the Ollama release the app embeds and keeps the Apple Silicon
# pieces in Vendor/ollama: the server binary and its llama-server helper.
# The x86 dylibs and the MLX Metal libraries in the tarball are not needed
# for the GGUF models the curator uses, and the app itself is arm64-only.
#
# Pinned; the checksum is of the tarball as published. Bump both together.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="0.33.2"
SHA256="5751e296a2cd545939bdd51b700de0c20d319f0e723c9d7f48bebb5ab0b731d4"
URL="https://github.com/ollama/ollama/releases/download/v$VERSION/ollama-darwin.tgz"
OUT="Vendor/ollama"
if [ -x "$OUT/ollama" ] && [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$VERSION" ]; then
    echo "Vendor/ollama is already $VERSION"
    exit 0
fi
TMP="$(mktemp -d)"
echo "downloading Ollama $VERSION…"
curl -sL --fail -o "$TMP/ollama-darwin.tgz" "$URL"
echo "$SHA256  $TMP/ollama-darwin.tgz" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch"; exit 1; }
mkdir -p "$TMP/x" && tar xzf "$TMP/ollama-darwin.tgz" -C "$TMP/x"
rm -rf "$OUT" && mkdir -p "$OUT"
lipo -thin arm64 "$TMP/x/ollama" -output "$OUT/ollama"
lipo -thin arm64 "$TMP/x/llama-server" -output "$OUT/llama-server"
chmod +x "$OUT/ollama" "$OUT/llama-server"
echo "$VERSION" > "$OUT/VERSION"
curl -sL --fail -o "$OUT/LICENSE" "https://raw.githubusercontent.com/ollama/ollama/v$VERSION/LICENSE" || true
rm -rf "$TMP"
echo "Vendor/ollama: $(du -sh "$OUT" | cut -f1) (Ollama $VERSION, arm64)"
