$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ("t3-skill-build-test-" + [guid]::NewGuid().ToString('N'))
$Work = Join-Path $Root 'work'
$Out = Join-Path $Root 'out'
$Scratch = Join-Path $Root 'scratch'
New-Item -ItemType Directory -Path $Work, $Out, $Scratch, "$Work/apps/server/dist/client", "$Work/scripts" | Out-Null
$Mock = @{ DockerRuns = 0; DockerStarts = 0; PackagingRuns = 0; State = 'missing'; BuildSha = '' }

function node {
    if ($args[0] -eq '-p') { '1.0.0' }
    elseif ($args[0] -ne '--input-type=module') { throw 'Unexpected node command' }
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
    if ($args[0] -ne 'run' -or $args[1] -ne 'dist:desktop:win:x64') { throw 'Wrong packaging command' }
    if ($args -notcontains '--skip-build' -or $args -notcontains '--wsl-runtime') { throw 'Missing WSL packaging argument' }
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
    git -C $Work add .
    git -C $Work commit -m fixture | Out-Null
    $Mock.BuildSha = (git -C $Work rev-parse HEAD).Trim()
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
    Write-Host 'PASS: pinned inputs; read-only source; WSL argument; fresh build; resume; active-build guard (mocked tooling)'
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
