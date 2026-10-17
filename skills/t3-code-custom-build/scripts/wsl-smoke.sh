#!/usr/bin/env bash
set -Eeuo pipefail
archive=${1:?archive path}
version=${2:?expected version}
scratch=$(mktemp -d /tmp/t3-as-custom-smoke.XXXXXXXX)
trap 'rm -rf "${scratch:?}"' EXIT
tar -xzf "$archive" -C "$scratch"
mkdir "$scratch/home"
cd "$scratch/t3-$version-linux-x64"
actual=$(env PATH='' HOME="$scratch/home" T3CODE_HOME="$scratch/home" ./t3 --version)
test "$actual" = "t3 v$version"
env PATH='' HOME="$scratch/home" T3CODE_HOME="$scratch/home" ./t3 --help >/dev/null
printf 'Native WSL smoke passed: %s\n' "$actual"
