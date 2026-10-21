#!/usr/bin/env bash
set -Eeuo pipefail
: "${BUILD_VERSION:?}" "${BUILD_SHA:?}" "${SEA_NODE_VERSION:?}" "${VITE_PLUS_VERSION:?}"
: "${LINUX_CACHE_NAMESPACE:?}"
: "${T3CODE_CLERK_PUBLISHABLE_KEY:?}" "${T3CODE_CLERK_JWT_TEMPLATE:?}" "${T3CODE_CLERK_CLI_OAUTH_CLIENT_ID:?}" "${T3CODE_RELAY_URL:?}"
export CI=true DEBIAN_FRONTEND=noninteractive
export VP_HOME="/cache/tools/vite-plus-$VITE_PLUS_VERSION" VP_VERSION="$VITE_PLUS_VERSION" VP_NODE_VERSION="$SEA_NODE_VERSION"
export PATH="/cache/tools/node-$SEA_NODE_VERSION/bin:$VP_HOME/bin:$PATH"
export CARGO_HOME=/cache/cargo

# System tools are installed once in the prepared image, never on the host/WSL distro.
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
vp install --frozen-lockfile --ignore-scripts -- --store-dir /cache/pnpm-store
echo "[$(date +%T)] Linux executable and resource monitor"
APP_VERSION="$BUILD_VERSION" node apps/server/scripts/cli.ts build-exe --verbose
mkdir -p apps/server/dist/client
cp -a /input/client/. apps/server/dist/client/
target=x86_64-unknown-linux-gnu
compiler=$( { printf '%s\n' "${LINUX_BUILD_INPUTS:?}"; rustc -vV; cc --version; } | sha256sum | cut -d ' ' -f 1)
target_root="/cache/targets/$LINUX_CACHE_NAMESPACE/$compiler/$target"
mkdir -p "$target_root"
# Hold the shared target lock through the copy: another build must not replace the executable.
exec 8>"$target_root/build.lock"
flock 8
export CARGO_TARGET_DIR="$target_root/release-build"
if [ "$(cat /input/rebuild)" = 1 ]; then
  export CARGO_TARGET_DIR
  CARGO_TARGET_DIR=$(mktemp -d "$target_root/rebuild.XXXXXXXX")
  trap 'rm -rf -- "$CARGO_TARGET_DIR"' EXIT
fi
# Never trust cross-container source mtimes (including after VM clock rollback).
# Clean only this package, retaining compiled registry dependencies.
package=$(cargo pkgid --locked --manifest-path native/resource-monitor/Cargo.toml)
cargo clean --locked --release --manifest-path native/resource-monitor/Cargo.toml --target "$target" --package "$package"
cargo build --locked --release --manifest-path native/resource-monitor/Cargo.toml --target "$target"
mkdir -p /build/resource-monitor/linux-x64
cp "$CARGO_TARGET_DIR/$target/release/t3-resource-monitor" /build/resource-monitor/linux-x64/
flock -u 8
echo "[$(date +%T)] Linux archive and server smoke test"
node scripts/build-cli-archive.ts --platform linux --arch x64 --version "$BUILD_VERSION" --resource-monitor-dir /build/resource-monitor --output-dir /out
node scripts/smoke-cli-archive.ts --archive "/out/t3-$BUILD_VERSION-linux-x64.tar.gz" --expect-version "$BUILD_VERSION"
sha256sum "/out/t3-$BUILD_VERSION-linux-x64.tar.gz"
