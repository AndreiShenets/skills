param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Scratch,
    [Parameter(Mandatory)][ValidatePattern('^\d{4}_\d{2}_\d{2}_\d{2}_\d{2}$')][string]$RunId,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$BuildKey,
    [switch]$Rebuild
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'git.ps1')
. (Join-Path $PSScriptRoot 'progress.ps1')
. (Join-Path $PSScriptRoot 'tooling.ps1')
. (Join-Path $PSScriptRoot 'checkpoints.ps1')
Assert-Clean $Worktree
$BuildSha = (git -C $Worktree rev-parse HEAD).Trim()
if (!$BuildKey) { $BuildKey = Get-CustomBuildKey -BuildSha $BuildSha -Version $Version -RunId $RunId }
$SourceTar = Join-Path $Scratch "source-$BuildSha.tar"
$Client = Join-Path $Worktree 'apps/server/dist/client'
if (!(Test-Path (Join-Path $Client 'index.html'))) { throw 'Build desktop/server/web first' }
$Config = Get-Content (Join-Path $Worktree 'apps/server/vite.config.ts') -Raw
$SeaNode = [regex]::Match($Config, 'const SEA_NODE_VERSION = ["'']([^"'']+)["'']').Groups[1].Value
if ($SeaNode -notmatch '^\d+\.\d+\.\d+$') { throw 'Inspect current SEA Node configuration' }
Push-Location $Worktree
try { $VpVersion = (node -p "require('vite-plus/package.json').version").Trim() }
finally { Pop-Location }
if ($VpVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Unexpected Vite+ version' }
Push-Location (Join-Path $Worktree 'scripts')
try {
    node --input-type=module -e 'import * as E from "effect/Effect"; import * as N from "@effect/platform-node/NodeServices"; import { preflightWindowsDesktopBuild as check } from "./build-desktop-artifact.ts"; await E.runPromise(check({arch:"x64",bundlesWslRuntime:true}).pipe(E.scoped,E.provide(N.layer)));'
} finally { Pop-Location }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
git -C $Worktree archive --format=tar "--output=$SourceTar" $BuildSha
$Name = "t3-as-custom-$($RunId.Replace('_', '-'))"
$Archive = Join-Path $OutputDir "t3-$Version-linux-x64.tar.gz"
$Installer = Join-Path $OutputDir "T3-Code-$Version-x64.exe"
$LinuxScript = Join-Path $PSScriptRoot 'linux-build.sh'
$Existing = docker ps --all --filter "name=^/$Name$" --format '{{.ID}}'
if ($Existing) {
    $State = (docker inspect --format '{{.State.Status}}' $Name).Trim()
    if ($State -notin @('exited', 'created')) { throw "Build container is $State; inspect $Name before retrying" }
    $ContainerEnv = docker inspect --format '{{json .Config.Env}}' $Name | ConvertFrom-Json
    if ($ContainerEnv -notcontains "BUILD_SHA=$BuildSha" -or $ContainerEnv -notcontains "BUILD_VERSION=$Version") {
        throw 'Existing container belongs to different build inputs; choose a new run ID'
    }
}
if (!$Rebuild -and (Test-BuildCheckpoint -Scratch $Scratch -Name linux -Key $BuildKey -Files @($Archive))) {
    Write-Host 'Reusing verified Linux archive'
} elseif ($Existing) {
    Clear-BuildCheckpoint -Scratch $Scratch -Name linux
    Invoke-BuildStep -Label 'Linux runtime (resume cached container)' -Action {
        docker start --attach $Name 2>&1 | Tee-Object (Join-Path $Scratch 'linux-build.log')
        if ($LASTEXITCODE -ne 0) { throw 'Linux container failed' }
    }
} else {
    Clear-BuildCheckpoint -Scratch $Scratch -Name linux
    Invoke-BuildStep -Label 'Linux runtime (shared tools, package and Cargo caches)' -Action {
        docker run --name $Name --platform linux/amd64 `
        --env "BUILD_VERSION=$Version" --env "BUILD_SHA=$BuildSha" `
        --env "SEA_NODE_VERSION=$SeaNode" --env "VITE_PLUS_VERSION=$VpVersion" `
        --mount "type=volume,source=$Name,target=/build" `
        --mount 'type=volume,source=t3-as-custom-linux-cache,target=/cache' `
        --mount "type=bind,source=$SourceTar,target=/input/source.tar,readonly" `
        --mount "type=bind,source=$LinuxScript,target=/input/build.sh,readonly" `
        --mount "type=bind,source=$Client,target=/input/client,readonly" `
        --mount "type=bind,source=$OutputDir,target=/out" `
        rust:bookworm bash /input/build.sh 2>&1 | Tee-Object (Join-Path $Scratch 'linux-build.log')
        if ($LASTEXITCODE -ne 0) { throw 'Linux container failed' }
    }
}
if (!(Test-Path $Archive)) { throw 'Linux archive missing' }
if ((git -C $Worktree rev-parse HEAD).Trim() -ne $BuildSha) { throw 'Source changed during Linux build' }
Assert-Clean $Worktree
Save-BuildCheckpoint -Scratch $Scratch -Name linux -Key $BuildKey -Files @($Archive)
if (!$Rebuild -and (Test-BuildCheckpoint -Scratch $Scratch -Name installer -Key $BuildKey -Files @($Archive, $Installer))) {
    Write-Host 'Reusing verified Windows installer'
    return
}
Clear-BuildCheckpoint -Scratch $Scratch -Name installer
Push-Location $Worktree
try {
    Invoke-BuildStep -Label 'Windows NSIS packaging and payload validation' -Action {
        Invoke-WorktreeVp -Worktree $Worktree -Arguments @('run', 'dist:desktop:win:x64', '--skip-build', '--build-version', $Version, '--wsl-runtime', $Archive, '--output-dir', $OutputDir) 2>&1 |
            Tee-Object (Join-Path $Scratch 'windows-build.log')
        if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed' }
    }
} finally { Pop-Location }
if (!(Test-Path (Join-Path $OutputDir "T3-Code-$Version-x64.exe"))) { throw 'Installer missing' }
if ((git -C $Worktree rev-parse HEAD).Trim() -ne $BuildSha) { throw 'Source changed during packaging' }
Assert-Clean $Worktree
Save-BuildCheckpoint -Scratch $Scratch -Name installer -Key $BuildKey -Files @($Archive, $Installer)
Write-Host "Built $BuildSha => $OutputDir"
