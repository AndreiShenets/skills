$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path 'C:/Temp/opencode' ("t3-skill-preflight-test-" + [guid]::NewGuid().ToString('N'))
$Work = Join-Path $Root 'work'
$Log = Join-Path $Root 'preflight.log'
$Mock = @{ Calls = @(); FailOn = ''; ExitCode = 0 }
$PreviousElectronRunAsNode = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', 'Process')

function vp {
    if ($env:ELECTRON_RUN_AS_NODE) { throw 'Harness environment leaked into preflight' }
    $Mock.Calls += ,@($args)
    $Kind = if ($args[0] -eq 'run' -or $args[0] -eq 'exec') { 'typecheck' } else { $args[0] }
    $global:LASTEXITCODE = if ($Kind -eq $Mock.FailOn) { $Mock.ExitCode } else { 0 }
    if ($LASTEXITCODE) { Write-Output 'simulated check failure' }
}

try {
    New-Item -ItemType Directory -Path "$Work/apps/web/src", "$Work/apps/untouched", "$Work/apps/deleted/src", "$Work/scripts" -Force | Out-Null
    git init --initial-branch=main $Work | Out-Null
    git -C $Work config user.name 'Skill Test'
    git -C $Work config user.email 'skill-test@example.invalid'
    git -C $Work config commit.gpgsign false
    git -C $Work config core.hooksPath (Join-Path $Root 'empty-hooks')
    Set-Content "$Work/apps/web/package.json" '{"name":"web","scripts":{"typecheck":"tsc-rs --noEmit"}}'
    Set-Content "$Work/apps/untouched/package.json" '{"name":"untouched","scripts":{"typecheck":"tsc-rs --noEmit"}}'
    Set-Content "$Work/apps/deleted/package.json" '{"name":"deleted","scripts":{"typecheck":"tsc-rs --noEmit"}}'
    Set-Content "$Work/apps/deleted/src/removed.ts" 'deleted source'
    Set-Content "$Work/apps/web/src/deleted.test.ts" 'old test'
    Set-Content "$Work/apps/web/src/existing.test.ts" 'existing test'
    Set-Content "$Work/apps/web/src/unchanged.test.ts" 'unrelated test'
    Set-Content "$Work/apps/web/src/existing.browser.test.tsx" 'unchanged browser sibling'
    Set-Content "$Work/apps/web/src/existing.live.spec.ts" 'unchanged live sibling'
    Set-Content "$Work/apps/web/src/unchanged.browser.test.tsx" 'unrelated browser test'
    Set-Content "$Work/scripts/tsconfig.json" '{}'
    git -C $Work add .
    git -C $Work commit -m baseline | Out-Null
    $Base = (git -C $Work rev-parse HEAD).Trim()
    Set-Content "$Work/apps/web/src/new file.ts" 'source'
    Set-Content "$Work/apps/web/src/new file.test.ts" 'test'
    Set-Content "$Work/apps/web/src/existing.ts" 'source with existing sibling test'
    Set-Content "$Work/apps/web/src/authorized.browser.test.tsx" 'browser test'
    Set-Content "$Work/apps/web/src/provider.live.test.ts" 'live test'
    Set-Content "$Work/scripts/build.ts" 'script'
    Remove-Item -LiteralPath "$Work/apps/web/src/deleted.test.ts"
    Remove-Item -LiteralPath "$Work/apps/deleted/src/removed.ts"
    git -C $Work add .
    git -C $Work commit -m customization | Out-Null
    . (Join-Path $PSScriptRoot '../scripts/preflight.ps1')
    $env:ELECTRON_RUN_AS_NODE = '1'
    $Location = (Get-Location).Path
    Invoke-CustomBuildPreflight -Worktree $Work -BaseRef $Base -LogPath $Log
    if ($env:ELECTRON_RUN_AS_NODE -ne '1' -or (Get-Location).Path -ne $Location) { throw 'Caller state was not restored' }
    if ($Mock.Calls.Count -ne 6) { throw 'Expected formatting, lint, package/scripts typechecks, and focused tests' }
    if ($Mock.Calls[0][0] -ne 'fmt' -or $Mock.Calls[1][0] -ne 'lint' -or $Mock.Calls[-1][0] -ne 'test') { throw 'Wrong validation order' }
    $Typecheck = @($Mock.Calls | Where-Object { $_[0] -eq 'run' })
    if ($Typecheck.Count -ne 2 -or $Typecheck[0][2] -ne './apps/deleted' -or $Typecheck[1][2] -ne './apps/web') {
        throw 'Typechecks must cover affected packages, including deletions, without checking unrelated packages'
    }
    $Test = $Mock.Calls[-1]
    if ($Test -notcontains 'apps/web/src/new file.test.ts' -or $Test -notcontains 'apps/web/src/existing.test.ts') { throw 'Missing changed/sibling test' }
    if (@($Test | Where-Object { $_ -match 'browser|live|deleted|unchanged' }).Count) { throw 'Unsafe or unrelated test selected' }
    if ((Get-Content $Log -Raw) -notmatch 'Manual verification not run.*authorized.browser.test.tsx') { throw 'Missing manual-test report' }
    foreach ($Sibling in @('existing.browser.test.tsx', 'existing.live.spec.ts')) {
        if ((Get-Content $Log -Raw) -notmatch "Manual verification not run.*$([regex]::Escape($Sibling))") {
            throw "Missing unchanged browser/live sibling report: $Sibling"
        }
    }
    if ((Get-Content $Log -Raw) -match 'Manual verification not run.*unchanged.browser.test.tsx') { throw 'Unrelated browser test was reported' }
    if ((Get-Content $Log -Raw) -notmatch 'PASS: Preflight focused tests') { throw 'Missing successful-check report' }

    $Attempt = 0
    foreach ($Kind in @('fmt', 'lint', 'typecheck', 'test')) {
        $PreviousLog = Get-Content $Log -Raw
        $Attempt++
        $Mock.Calls = @()
        $Mock.FailOn = $Kind
        $Mock.ExitCode = 2
        $Failed = $false
        try { Invoke-CustomBuildPreflight -Worktree $Work -BaseRef $Base -LogPath $Log } catch {
            if ($_.Exception.Message -notlike '*failed (exit 2)*') { throw }
            $Failed = $true
        }
        if (!$Failed -or $env:ELECTRON_RUN_AS_NODE -ne '1' -or (Get-Location).Path -ne $Location) { throw 'Failure did not stop checks or restore caller state' }
        if ((Get-Content $Log -Raw) -notmatch 'FAIL: .*exit 2') { throw 'Missing failed-check report' }
        $ArchivedLog = Join-Path $Root ('preflight.attempt-{0:D4}.log' -f $Attempt)
        if (!(Test-Path $ArchivedLog) -or (Get-Content $ArchivedLog -Raw) -cne $PreviousLog) { throw 'Retry overwrote the previous attempt log' }
        if ($Kind -ne 'test' -and @($Mock.Calls | Where-Object { $_[0] -eq 'test' }).Count) { throw 'Checks continued after failure' }
    }
    $Mock.Calls = @()
    $Mock.FailOn = ''
    $FailedLog = Get-Content $Log -Raw
    Invoke-CustomBuildPreflight -Worktree $Work -BaseRef HEAD -LogPath $Log
    if ($Mock.Calls.Count) { throw 'Empty scopes must not run repository-wide checks' }
    if ((Get-Content (Join-Path $Root 'preflight.attempt-0005.log') -Raw) -cne $FailedLog) { throw 'Successful retry lost the failed test log' }
    if ((Get-Content (Join-Path $Root 'preflight.attempt-0001.log') -Raw) -notmatch 'PASS: Preflight focused tests') { throw 'Later retries changed an earlier archive' }
    Write-Host 'PASS: scoped checks; unchanged browser/live siblings; numbered retry logs; nonzero exit guards; environment restoration'
} finally {
    [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $PreviousElectronRunAsNode, 'Process')
    Remove-Item -LiteralPath $Root -Recurse -Force
}
