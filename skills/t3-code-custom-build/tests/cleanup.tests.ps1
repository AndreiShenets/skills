$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '../scripts/cleanup.ps1')
$Name = 't3-as-custom-2026-10-20-07-58'
$Mock = @{ Container = $true; Volume = $true; Status = 'exited'; Sha = 'source'; Mount = $Name; Removes = @(); FailVolume = $true }
$State = @{ ReleaseUrl = 'https://example.invalid/release'; RunId = '2026_10_20_07_58'; BuildSha = 'source'; Version = '0.1.1'; CleanupPending = $true }
function docker {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        ps { if ($Mock.Container) { $Name } }
        inspect { @{ Name = "/$Name"; State = @{ Status = $Mock.Status }; Config = @{ Env = @("BUILD_SHA=$($Mock.Sha)", 'BUILD_VERSION=0.1.1') }; Mounts = @(@{ Destination = '/build'; Type = 'volume'; Name = $Mock.Mount }) } | ConvertTo-Json -Depth 5 }
        rm {
            if ($args.Count -ne 2 -or $args[1] -cne $Name -or !$State.CleanupVolumeVerified) { throw 'Unsafe container deletion' }
            $Mock.Removes += 'container'; $Mock.Container = $false
        }
        volume {
            if ($args[1] -eq 'ls') { if ($Mock.Volume) { $Name; 't3-as-custom-linux-cache' }; return }
            if ($args[1] -ne 'rm' -or $args.Count -ne 3 -or $args[2] -cne $Name) { throw 'Unsafe volume deletion' }
            if ($Mock.FailVolume) { throw 'simulated volume removal failure' }
            $Mock.Removes += 'volume'; $Mock.Volume = $false
        }
        default { throw 'Unexpected Docker call' }
    }
}
foreach ($Case in @('running', 'source-mismatch', 'mount-mismatch', 'unpublished')) {
    $Mock.Status = if ($Case -eq 'running') { 'running' } else { 'exited' }
    $Mock.Sha = if ($Case -eq 'source-mismatch') { 'other' } else { 'source' }
    $Mock.Mount = if ($Case -eq 'mount-mismatch') { 't3-as-custom-linux-cache' } else { $Name }
    $State.ReleaseUrl = if ($Case -eq 'unpublished') { '' } else { 'https://example.invalid/release' }
    $Failed = $false
    try { Remove-PublishedBuildResources -State $State -SaveState {} } catch { $Failed = $true }
    if (!$Failed -or $Mock.Removes.Count) { throw "Unsafe cleanup was not blocked: $Case" }
}
$State.ReleaseUrl = 'https://example.invalid/release'; $Mock.Status = 'exited'; $Mock.Sha = 'source'; $Mock.Mount = $Name
try { Remove-PublishedBuildResources -State $State -SaveState {} } catch {
    if ($_.Exception.Message -ne 'simulated volume removal failure') { throw }
}
if ($Mock.Container -or !$Mock.Volume -or !$State.CleanupPending -or $State.CleanupVolumeVerified -cne $Name) { throw 'Interrupted cleanup lost its recovery record' }
$Mock.FailVolume = $false
Remove-PublishedBuildResources -State $State -SaveState {}
Remove-PublishedBuildResources -State $State -SaveState {}
if ($Mock.Volume -or $State.CleanupPending -or ($Mock.Removes -join ',') -ne 'container,volume') { throw 'Cleanup retry was not idempotent' }
$Mock.Volume = $true; $State.CleanupVolumeVerified = ''
$Failed = $false
try { Remove-PublishedBuildResources -State $State -SaveState {} } catch { $Failed = $true }
if (!$Failed) { throw 'Unverified orphan volume was removed' }
Write-Host 'PASS: verified stopped-run cleanup; shared cache protection; failure retention; interrupted cleanup recovery; absent resources; orphan refusal'
