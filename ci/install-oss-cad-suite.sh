#!/usr/bin/env bash
# Install the oss-cad-suite release used by the regression (Icarus Verilog and
# Yosys). Installs into a caller-owned prefix, so CI and containers need no sudo.
set -euo pipefail

VERSION="${OSS_CAD_VERSION:-2026-10-24}"
PREFIX="${1:-/tmp/rv64_core-$(id -u)/oss-cad-suite}"

if [ -x "$PREFIX/bin/iverilog" ]; then
    echo "oss-cad-suite already installed at $PREFIX"
    exit 0
fi

mkdir -p "$(dirname "$PREFIX")"
url="https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${VERSION}/oss-cad-suite-linux-x64-$(echo "$VERSION" | tr -d '-').tgz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $url"
curl -sSL --fail -o "$tmp/ocs.tgz" "$url"
tar -xzf "$tmp/ocs.tgz" -C "$(dirname "$PREFIX")"

"$PREFIX/bin/iverilog" -V | head -1
