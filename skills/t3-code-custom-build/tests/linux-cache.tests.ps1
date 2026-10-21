$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Scripts = Join-Path $PSScriptRoot '../scripts'
. (Join-Path $Scripts 'progress.ps1')
. (Join-Path $Scripts 'linux-cache.ps1')
$Fixture = @{ Present = $false; Builds = 0; FailBuild = $false; Image = ('sha256:' + ('a' * 64)); Tags = @() }
function docker {
    if ($args[0] -eq 'image') {
        $Fixture.Tags += $args[-1]
        if ($Fixture.Present) { $Fixture.Image; $global:LASTEXITCODE = 0 }
        else { $global:LASTEXITCODE = 1 }
    } elseif ($args[0] -eq 'build') {
        if ($args -notcontains 'linux/amd64' -or $args[-1] -ne '-') { throw 'Image build must use amd64 and an empty stdin context' }
        $Fixture.Builds++
        $Fixture.Present = !$Fixture.FailBuild
        $global:LASTEXITCODE = if ($Fixture.FailBuild) { 1 } else { 0 }
    } else { throw 'Unexpected Docker command' }
}
function Get-BuildCacheDirectory {
    param([string]$Worktree)
    if ($Worktree -eq 'different') { 'D:/fixture/other/release/as-custom/cache' }
    else { 'D:/fixture/main/release/as-custom/cache' }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw $Message }
}

$Image = Get-LinuxBuildImage -Worktree main
Assert-Equal $Image $Fixture.Image 'Prepared image must return only an immutable ID'
Assert-Equal $Fixture.Builds 1 'Missing image was not prepared exactly once'
Assert-Equal (Get-LinuxBuildImage -Worktree nested) $Image 'Existing image identity changed'
Assert-Equal $Fixture.Builds 1 'Warm image was rebuilt'
$ExpectedTag = 't3-as-custom-linux-build:' + (Get-FileHash (Join-Path $Scripts 'linux-build.Dockerfile')).Hash.ToLowerInvariant()
if (@($Fixture.Tags | Where-Object { $_ -cne $ExpectedTag }).Count) { throw 'Image lookup is not keyed by Dockerfile hash' }
$Fixture.Present = $false
$Fixture.FailBuild = $true
$Failed = $false
try { Get-LinuxBuildImage -Worktree main } catch { $Failed = $_.Exception.Message -eq 'Could not prepare Linux build image' }
if (!$Failed) { throw 'Failed image preparation was accepted' }
$Fixture.Present = $true
$Fixture.Image = 'mutable:tag'
$Failed = $false
try { Get-LinuxBuildImage -Worktree main } catch { $Failed = $_.Exception.Message -eq 'Invalid Linux build image identity' }
if (!$Failed) { throw 'Mutable image reference was accepted' }
$Namespace = Get-LinuxCacheNamespace -Worktree main
Assert-Equal (Get-LinuxCacheNamespace -Worktree linked) $Namespace 'Linked checkout cache differs'
Assert-Equal (Get-LinuxCacheNamespace -Worktree nested) $Namespace 'Nested checkout cache differs'
if ((Get-LinuxCacheNamespace -Worktree different) -ceq $Namespace) { throw 'Different repositories share a target namespace' }
$Inputs = @{ ImageId = $Image; SeaNode = '26.8.2'; VpVersion = '1.0.0'; CacheNamespace = $Namespace }
$Original = Get-LinuxBuildInputs @Inputs
foreach ($Key in @('ImageId', 'SeaNode', 'VpVersion', 'CacheNamespace')) {
    $Changed = $Inputs.Clone()
    $Changed[$Key] += '-changed'
    if ((Get-LinuxBuildInputs @Changed) -ceq $Original) { throw "Resume identity ignores $Key" }
}

# Exercise the actual Cargo section with fake tools; no Docker daemon or Rust installation needed.
$Bash = 'bash'
if (!(Get-Command $Bash -ErrorAction SilentlyContinue)) { throw 'Bash required for Cargo cache tests' }
$Root = Join-Path ([IO.Path]::GetTempPath()) ('t3-linux-cache-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null
try {
    $Linux = Get-Content (Join-Path $Scripts 'linux-build.sh') -Raw
    $Start = $Linux.IndexOf('target=x86_64-unknown-linux-gnu')
    $End = $Linux.IndexOf('flock -u 8', $Start) + 'flock -u 8'.Length
    $Cargo = $Linux.Substring($Start, $End - $Start).Replace('/cache/targets', '"$TEST_ROOT/cache"').Replace('/input/rebuild', '"$TEST_ROOT/rebuild"').Replace('/build/resource-monitor', '"$TEST_ROOT/output"')
    $Harness = @'
set -Eeuo pipefail
export TEST_ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TEST_ROOT/source"
cd "$TEST_ROOT/source"
export LINUX_CACHE_NAMESPACE=fixture
export LINUX_BUILD_INPUTS=fixture-tools
rustc() { echo compiler-fixture; }
cc() { echo cc-fixture; }
cargo() {
  [[ " $* " == *' --locked '* ]]
  if [ "$1" = pkgid ]; then echo 'path+file:///build/t3code/native/resource-monitor#fixture@0.1.0'; return; fi
  if [ "$1" = clean ]; then
    [[ " $* " == *' --package path+file:///build/t3code/native/resource-monitor#fixture@0.1.0 '* ]]
    rm -f "$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/t3-resource-monitor"
    return
  fi
  test "$1" = build
  echo "$CARGO_TARGET_DIR" >> "$TEST_ROOT/targets"
  if [ "${FAIL_CARGO:-0}" = 1 ]; then return 37; fi
  mkdir -p "$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release"
  # Model Cargo mistakenly accepting an old binary after source/clock rollback.
  if [ ! -f "$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/t3-resource-monitor" ]; then
    cat input.rs > "$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/t3-resource-monitor"
  fi
}
cp() {
  # The target lock must remain held until the executable has been copied.
  if flock -n "$target_root/build.lock" true; then echo 'Unlocked copy' >&2; exit 9; fi
  command cp "$@"
}
if [ "${1:-}" = --fail ]; then
  export FAIL_CARGO=1
  __CARGO__
  exit 0
fi
echo 0 > "$TEST_ROOT/rebuild"
echo first > input.rs
( __CARGO__ )
test "$(cat "$TEST_ROOT/output/linux-x64/t3-resource-monitor")" = first
echo second > input.rs
touch -t 200001010000 input.rs
( __CARGO__ )
test "$(cat "$TEST_ROOT/output/linux-x64/t3-resource-monitor")" = second
test "$(sed -n '1p' "$TEST_ROOT/targets")" = "$(sed -n '2p' "$TEST_ROOT/targets")"
echo 1 > "$TEST_ROOT/rebuild"
( __CARGO__ )
test "$(sed -n '1p' "$TEST_ROOT/targets")" != "$(sed -n '3p' "$TEST_ROOT/targets")"
test ! -d "$(sed -n '3p' "$TEST_ROOT/targets")"
echo 0 > "$TEST_ROOT/rebuild"
if bash "$0" --fail; then exit 10; fi
test "$(cat "$TEST_ROOT/output/linux-x64/t3-resource-monitor")" = second
echo 'PASS: locked Cargo execution, shared target reuse, rollback-safe package cleaning, forced rebuild, lock through copy, compilation failure'
'@
    $Harness = $Harness.Replace('__CARGO__', $Cargo)
    $File = Join-Path $Root 'cargo-cache.sh'
    [IO.File]::WriteAllText($File, $Harness.Replace("`r`n", "`n"))
    if ($IsWindows) {
        $BashFile = (wsl.exe --exec wslpath -u $File).Trim()
        wsl.exe --exec bash $BashFile
    } else { & $Bash $File }
    if ($LASTEXITCODE -ne 0) { throw 'Cargo cache behavior tests failed' }
    $LinuxFile = (Resolve-Path (Join-Path $Scripts 'linux-build.sh')).Path
    if ($IsWindows) {
        $LinuxFile = (wsl.exe --exec wslpath -u $LinuxFile).Trim()
        wsl.exe --exec bash -n $LinuxFile
    } else { & $Bash -n $LinuxFile }
    if ($LASTEXITCODE -ne 0) { throw 'Linux script syntax check failed' }
    Write-Host 'PASS: lazy prepared image, immutable identity, build failure, repository-relative namespace, resume input identity, Bash syntax'
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
