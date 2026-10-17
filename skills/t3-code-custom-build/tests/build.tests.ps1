$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ("t3-skill-build-test-" + [guid]::NewGuid().ToString('N'))
$Work = Join-Path $Root 'work'
$Out = Join-Path $Root 'out'
$Scratch = Join-Path $Root 'scratch'
New-Item -ItemType Directory -Path $Work, $Out, $Scratch, "$Work/apps/server/dist/client", "$Work/scripts" | Out-Null
$Mock = @{ DockerRuns = 0; DockerStarts = 0; PackagingRuns = 0; FrontendRuns = 0; FailFrontend = $false; State = 'missing'; BuildSha = ''; CacheMounts = @(); SourceMounts = @(); StorePaths = @() }
$PreviousAppVersion = [Environment]::GetEnvironmentVariable('APP_VERSION', 'Process')
$PreviousDesktopVersion = [Environment]::GetEnvironmentVariable('T3CODE_DESKTOP_VERSION', 'Process')

function node {
    if ($args[0] -eq '-p') { '1.0.0' }
    elseif ($args[0] -eq 'scripts/apply-web-brand-assets.ts') {
        if ($env:APP_VERSION -ne '0.1.1') { throw 'Branding saw inherited APP_VERSION' }
    } elseif ($args[0] -notin @('--input-type=module', 'scripts/update-release-package-versions.ts')) { throw 'Unexpected node command' }
    $global:LASTEXITCODE = 0
}

function docker {
    switch ($args[0]) {
        'ps' { if ($Mock.State -ne 'missing') { 'fixture-container' } }
        'inspect' {
            if ($args -contains '{{.State.Status}}') { $Mock.State }
            else { ConvertTo-Json @("BUILD_SHA=$($Mock.BuildSha)", 'BUILD_VERSION=0.1.1') -Compress }
        }
        'run' {
            if ($args -notcontains "BUILD_SHA=$($Mock.BuildSha)") { throw 'Wrong source SHA' }
            if ($args -notcontains 'SEA_NODE_VERSION=26.8.2') { throw 'SEA version not derived from source' }
            if ($args -notcontains 'VITE_PLUS_VERSION=1.0.0') { throw 'Vite+ version not derived from installation' }
            foreach ($Target in @('/input/source.tar', '/input/build.sh', '/input/client')) {
                if (!($args | Where-Object { $_ -like "*target=$Target,readonly" })) { throw "Writable input: $Target" }
            }
            $CacheMount = @($args | Where-Object { $_ -eq 'type=volume,source=t3-as-custom-linux-cache,target=/cache' })
            if ($CacheMount.Count -ne 1) { throw 'Missing reusable Linux cache volume' }
            $Mock.CacheMounts += $CacheMount[0]
            $Mock.SourceMounts += @($args | Where-Object { $_ -like 'type=volume,source=*,target=/build' })
            Set-Content (Join-Path $Out 't3-0.1.1-linux-x64.tar.gz') 'mock archive'
            $Mock.DockerRuns++
            $Mock.State = 'exited'
        }
        'start' { $Mock.DockerStarts++ }
        default { throw 'Unexpected Docker command' }
    }
    $global:LASTEXITCODE = 0
}

function vp {
    if ($args[0] -eq 'install') {
        $StoreIndex = [array]::IndexOf($args, '--store-dir')
        if ($StoreIndex -lt 0) { throw 'Windows install has no reusable store' }
        # PowerShell consumes the separator for this function mock, unlike native vp.
        if ($MyInvocation.Line -notmatch '\s--\s+--store-dir(?:\s|$)') {
            throw 'Package-manager options must follow the vp pass-through separator'
        }
        $Mock.StorePaths += $args[$StoreIndex + 1]
        $global:LASTEXITCODE = 0
        return
    }
    if ($args[0] -eq 'run' -and $args[1] -eq 'build:desktop') {
        if ($env:APP_VERSION -ne '0.1.1') { throw 'Frontend saw inherited APP_VERSION' }
        if ($Mock.FailFrontend) { throw 'simulated frontend failure' }
        $Mock.FrontendRuns++
        $global:LASTEXITCODE = 0
        return
    }
    if ($args[0] -ne 'run' -or $args[1] -ne 'dist:desktop:win:x64') { throw 'Wrong packaging command' }
    if ($args -notcontains '--skip-build' -or $args -notcontains '--wsl-runtime') { throw 'Missing WSL packaging argument' }
    $VersionIndex = [array]::IndexOf($args, '--build-version')
    if ($VersionIndex -lt 0 -or $args[$VersionIndex + 1] -ne '0.1.1') { throw 'Inherited desktop version was not overridden' }
    if ($args -notcontains (Join-Path $Out 't3-0.1.1-linux-x64.tar.gz')) { throw 'Wrong Linux archive' }
    Set-Content (Join-Path $Out 'T3-Code-0.1.1-x64.exe') 'mock installer'
    $Mock.PackagingRuns++
    $global:LASTEXITCODE = 0
}

try {
    git init --initial-branch=main $Work | Out-Null
    git -C $Work config user.name 'Skill Test'
    git -C $Work config user.email 'skill-test@example.invalid'
    git -C $Work config commit.gpgsign false
    git -C $Work config core.hooksPath (Join-Path $Root 'empty-hooks')
    Set-Content "$Work/apps/server/dist/client/index.html" '<html></html>'
    Set-Content "$Work/apps/server/vite.config.ts" 'const SEA_NODE_VERSION = "26.8.2";'
    foreach ($Package in @('apps/server', 'apps/desktop', 'apps/web', 'packages/contracts')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Work $Package) | Out-Null
        Set-Content (Join-Path $Work "$Package/package.json") '{"version":"0.1.1"}'
    }
    git -C $Work add .
    git -C $Work commit -m fixture | Out-Null
    $Mock.BuildSha = (git -C $Work rev-parse HEAD).Trim()
    git init --bare --initial-branch=main (Join-Path $Root 'origin.git') | Out-Null
    git -C $Work remote add origin (Join-Path $Root 'origin.git')
    $env:APP_VERSION = '9.9.9'
    $env:T3CODE_DESKTOP_VERSION = '9.9.9'
    $Helper = Join-Path $PSScriptRoot '../scripts/build-with-wsl.ps1'
    & $Helper -Worktree $Work -Scratch $Scratch -RunId 2026_10_17_15_39 -Version 0.1.1 -OutputDir $Out
    & $Helper -Worktree $Work -Scratch $Scratch -RunId 2026_10_17_15_39 -Version 0.1.1 -OutputDir $Out
    if ($Mock.DockerRuns -ne 1 -or $Mock.DockerStarts -ne 1 -or $Mock.PackagingRuns -ne 2) {
        throw 'Fresh build/resume did not execute expected stages'
    }
    $Mock.State = 'running'
    $Blocked = $false
    try {
        & $Helper -Worktree $Work -Scratch $Scratch -RunId 2026_10_17_15_39 -Version 0.1.1 -OutputDir $Out
    } catch {
        if ($_.Exception.Message -notlike 'Build container is running*') { throw }
        $Blocked = $true
    }
    if (!$Blocked -or $Mock.PackagingRuns -ne 2) { throw 'Active-build guard failed' }

    $Mock.State = 'exited'
    $Run = Join-Path $Scratch 'run.json'
    @{
        Merged = $true; Built = $false; Work = $Work; BuildBranch = 'main'; Scratch = $Scratch
        Version = '0.1.1'; Stamp = '202610171539'; RunId = '2026_10_17_15_39'; Out = $Out; BuildSha = ''
    } | ConvertTo-Json | Set-Content $Run
    $Workflow = Join-Path $PSScriptRoot '../scripts/workflow.ps1'
    & $Workflow -Stage Build -Run $Run
    if ($Mock.FrontendRuns -ne 1 -or $Mock.PackagingRuns -ne 3) { throw 'Build stage did not complete' }
    if ($env:APP_VERSION -ne '9.9.9' -or $env:T3CODE_DESKTOP_VERSION -ne '9.9.9') { throw 'Build changed caller environment' }
    $Mock.FailFrontend = $true
    $Failed = $false
    try { & $Workflow -Stage Build -Run $Run } catch {
        if ($_.Exception.Message -ne 'simulated frontend failure') { throw }
        $Failed = $true
    }
    if (!$Failed -or $env:APP_VERSION -ne '9.9.9' -or (Get-Content $Run -Raw | ConvertFrom-Json).Built) {
        throw 'Failed build did not restore environment or clear completion state'
    }
    $Mock.State = 'missing'
    & $Helper -Worktree $Work -Scratch $Scratch -RunId 2026_10_17_16_00 -Version 0.1.1 -OutputDir $Out
    if (@($Mock.CacheMounts | Sort-Object -Unique).Count -ne 1 -or @($Mock.SourceMounts | Sort-Object -Unique).Count -ne 2) {
        throw 'Different runs must share caches but not source workspaces'
    }
    $ExpectedStore = [IO.Path]::GetFullPath((Join-Path $Work '.git/as-custom/cache/pnpm-store'))
    if ($Mock.StorePaths.Count -ne 2 -or @($Mock.StorePaths | Where-Object { [IO.Path]::GetFullPath($_) -ne $ExpectedStore }).Count) {
        throw 'Windows store was not reused outside the run scratch directory'
    }
    Write-Host 'PASS: pinned versions; environment restoration; isolated sources; per-run containers with reusable caches; build/resume guards'
} finally {
    [Environment]::SetEnvironmentVariable('APP_VERSION', $PreviousAppVersion, 'Process')
    [Environment]::SetEnvironmentVariable('T3CODE_DESKTOP_VERSION', $PreviousDesktopVersion, 'Process')
    Remove-Item -LiteralPath $Root -Recurse -Force
}
