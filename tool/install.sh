#!/bin/sh
# FlutterX installer — downloads the right prebuilt binary from GitHub
# Releases, verifies its sha256, and installs it into the store's bin dir
# (docs/08 §7). No Dart SDK required.
#
#   curl -fsSL https://raw.githubusercontent.com/muhammadsaddamnur/flutterX/main/tool/install.sh | sh
#
# Overrides: FLUTTERX_VERSION (tag, default latest), FLUTTERX_HOME.
set -eu

REPO="muhammadsaddamnur/flutterX"
FLUTTERX_HOME="${FLUTTERX_HOME:-$HOME/.flutterx}"
BIN_DIR="$FLUTTERX_HOME/bin"

# ── Detect OS/arch → release asset name ──────────────────────────────────
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os_tag="macos" ;;
  Linux)  os_tag="linux" ;;
  *) echo "flutterx: unsupported OS '$os' — build from source (see README)." >&2; exit 1 ;;
esac
case "$arch" in
  arm64|aarch64) arch_tag="arm64" ;;
  x86_64|amd64)  arch_tag="x64" ;;
  *) echo "flutterx: unsupported arch '$arch'." >&2; exit 1 ;;
esac
# Only macOS ships arm64 today; Linux is x64.
if [ "$os_tag" = "linux" ]; then arch_tag="x64"; fi
asset="flutterx-${os_tag}-${arch_tag}"

# ── Resolve the release tag ──────────────────────────────────────────────
version="${FLUTTERX_VERSION:-}"
if [ -z "$version" ]; then
  version="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)"
fi
if [ -z "$version" ]; then
  echo "flutterx: no published release found. Build from source (see README)." >&2
  exit 1
fi
base="https://github.com/$REPO/releases/download/$version"

echo "flutterx: installing $version ($asset) into $BIN_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── Download + verify ────────────────────────────────────────────────────
curl -fSL "$base/$asset" -o "$tmp/flutterx"
curl -fsSL "$base/$asset.sha256" -o "$tmp/flutterx.sha256" || true
if [ -s "$tmp/flutterx.sha256" ]; then
  expected="$(cut -d' ' -f1 < "$tmp/flutterx.sha256")"
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$tmp/flutterx" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$tmp/flutterx" | cut -d' ' -f1)"
  fi
  if [ "$expected" != "$actual" ]; then
    echo "flutterx: checksum mismatch — refusing to install." >&2
    exit 1
  fi
else
  echo "flutterx: warning — no checksum published; skipping verification." >&2
fi

# ── Install ──────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
mv "$tmp/flutterx" "$BIN_DIR/flutterx"
chmod 755 "$BIN_DIR/flutterx"

echo "✓ flutterx $version installed."
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    echo
    echo "Add the store's bin dir to your PATH (also activates the"
    echo "transparent flutter/dart shims):"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac
echo "Then run: flutterx doctor"
