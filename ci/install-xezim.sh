#!/usr/bin/env bash
# Install xezim, the SystemVerilog simulator used for the UVM regression.
# Installs into a caller-owned prefix, so CI and containers need no sudo.
set -euo pipefail

VERSION="${XEZIM_VERSION:-0.11.3}"
PREFIX="${1:-/tmp/rv64_core-$(id -u)/xezim}"

if [ -x "$PREFIX/bin/xezim" ]; then
    echo "xezim already installed at $PREFIX"
    exit 0
fi

mkdir -p "$(dirname "$PREFIX")"
url="https://github.com/EDAPack/xezim-bin/releases/download/v${VERSION}/xezim-manylinux_2_34_x86_64-${VERSION}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $url"
curl -sSL --fail -o "$tmp/xezim.tgz" "$url"
tar -xzf "$tmp/xezim.tgz" -C "$tmp"
mv "$tmp/xezim" "$PREFIX"
echo "xezim installed at $PREFIX"
