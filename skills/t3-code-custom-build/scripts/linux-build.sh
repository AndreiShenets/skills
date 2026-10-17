#!/usr/bin/env bash
set -Eeuo pipefail
: "${BUILD_VERSION:?}" "${BUILD_SHA:?}" "${SEA_NODE_VERSION:?}" "${VITE_PLUS_VERSION:?}"
export CI=true DEBIAN_FRONTEND=noninteractive
export VP_HOME="/cache/tools/vite-plus-$VITE_PLUS_VERSION" VP_VERSION="$VITE_PLUS_VERSION" VP_NODE_VERSION="$SEA_NODE_VERSION"
export PATH="/cache/tools/node-$SEA_NODE_VERSION/bin:$VP_HOME/bin:$PATH"
export CARGO_HOME=/cache/cargo

# Tool installation is confined to the container, never the host/WSL distro.
if ! command -v python3 >/dev/null || ! command -v pkg-config >/dev/null; then
  apt-get update
  apt-get install -y --no-install-recommends python3 pkg-config ca-certificates
fi
mkdir -p /cache/downloads
# Serialize first-time tool installation; concurrent builds keep their sources and outputs isolated.
exec 9>/cache/tools.lock
flock 9
if [ ! -f "/cache/tools/node-$SEA_NODE_VERSION/.installed" ]; then
  mkdir -p "/cache/tools/node-$SEA_NODE_VERSION"
  cd /cache/downloads
  archive="node-v$SEA_NODE_VERSION-linux-x64.tar.xz"
  curl --fail --location --retry 3 -O "https://nodejs.org/dist/v$SEA_NODE_VERSION/$archive"
  curl --fail --location --retry 3 -o SHASUMS256.txt "https://nodejs.org/dist/v$SEA_NODE_VERSION/SHASUMS256.txt"
  grep " $archive\$" SHASUMS256.txt | sha256sum --check -
  tar -xJf "$archive" -C "/cache/tools/node-$SEA_NODE_VERSION" --strip-components=1
  touch "/cache/tools/node-$SEA_NODE_VERSION/.installed"
fi
if [ ! -f "$VP_HOME/.installed" ]; then
  curl --fail --location --retry 3 -o /cache/vite-plus-install.sh https://vite.plus
  bash /cache/vite-plus-install.sh
  touch "$VP_HOME/.installed"
fi
flock -u 9
node --version
cargo --version
cc --version
vp --version

if [ -f /build/source.sha ]; then
  test "$(cat /build/source.sha)" = "$BUILD_SHA"
else
  mkdir -p /build/t3code
  tar -xf /input/source.tar -C /build/t3code
  printf '%s\n' "$BUILD_SHA" > /build/source.sha
fi
cd /build/t3code
node --input-type=module -e '
  import fs from "node:fs";
  for (const p of ["apps/server", "apps/desktop", "apps/web", "packages/contracts"]) {
    if (JSON.parse(fs.readFileSync(`${p}/package.json`)).version !== process.env.BUILD_VERSION) {
      throw new Error(`Version mismatch: ${p}`);
    }
  }
'
echo "[$(date +%T)] Linux dependencies (shared store)"
vp install --frozen-lockfile --ignore-scripts --store-dir /cache/pnpm-store
echo "[$(date +%T)] Linux executable and resource monitor"
APP_VERSION="$BUILD_VERSION" node apps/server/scripts/cli.ts build-exe --verbose
mkdir -p apps/server/dist/client
cp -a /input/client/. apps/server/dist/client/
cargo build --locked --release --manifest-path native/resource-monitor/Cargo.toml --target x86_64-unknown-linux-gnu
mkdir -p /build/resource-monitor/linux-x64
cp native/resource-monitor/target/x86_64-unknown-linux-gnu/release/t3-resource-monitor /build/resource-monitor/linux-x64/
echo "[$(date +%T)] Linux archive and server smoke test"
node scripts/build-cli-archive.ts --platform linux --arch x64 --version "$BUILD_VERSION" --resource-monitor-dir /build/resource-monitor --output-dir /out
node scripts/smoke-cli-archive.ts --archive "/out/t3-$BUILD_VERSION-linux-x64.tar.gz" --expect-version "$BUILD_VERSION"
sha256sum "/out/t3-$BUILD_VERSION-linux-x64.tar.gz"
