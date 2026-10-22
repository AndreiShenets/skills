$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-skill-preflight-test-" + [guid]::NewGuid().ToString('N'))
$Work = Join-Path $Root 'work'
$Log = Join-Path $Root 'preflight.log'
$Mock = @{ Calls = @(); FailOn = ''; ExitCode = 0 }
$PreviousElectronRunAsNode = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', 'Process')

function node {
    if ($args[0] -notmatch '[\\/]bin[\\/]vp$') { throw 'Preflight did not invoke the worktree-local Node CLI' }
    $Arguments = @($args | Select-Object -Skip 1)
    if ($env:ELECTRON_RUN_AS_NODE) { throw 'Harness environment leaked into preflight' }
    $Mock.Calls += ,$Arguments
    $Kind = if ($Arguments[-1] -eq 'ensure:electron') { 'electron' }
        elseif ($Arguments[0] -eq 'run' -or $Arguments[0] -eq 'exec') { 'typecheck' }
        else { $Arguments[0] }
    $global:LASTEXITCODE = if ($Kind -eq $Mock.FailOn) { $Mock.ExitCode } else { 0 }
    if ($LASTEXITCODE) { Write-Output 'simulated check failure' }
}

try {
    New-Item -ItemType Directory -Path "$Work/apps/web/src", "$Work/apps/desktop", "$Work/apps/untouched", "$Work/apps/deleted/src", "$Work/scripts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$Work/node_modules/vite-plus/bin" -Force | Out-Null
    Set-Content "$Work/node_modules/vite-plus/package.json" '{"bin":{"vp":"bin/vp"}}'
    Set-Content "$Work/node_modules/vite-plus/bin/vp" 'fixture CLI'
    Set-Content "$Work/.gitignore" 'node_modules/'
    git init --initial-branch=main $Work | Out-Null
    git -C $Work config user.name 'Skill Test'
    git -C $Work config user.email 'skill-test@example.invalid'
    git -C $Work config commit.gpgsign false
    git -C $Work config core.hooksPath (Join-Path $Root 'empty-hooks')
    Set-Content "$Work/apps/web/package.json" '{"name":"web"}'
    Set-Content "$Work/apps/web/vite.config.ts" 'export default { run: { tasks: { typecheck: { command: "tsc-rs --noEmit" } } } };'
    Set-Content "$Work/apps/desktop/package.json" '{"name":"desktop","scripts":{"ensure:electron":"node scripts/ensure-electron-runtime.mjs"}}'
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
    if ($Mock.Calls.Count -ne 7) { throw 'Expected formatting, lint, package/scripts typechecks, Electron initialization, and focused tests' }
    if ($Mock.Calls[0][0] -ne 'fmt' -or $Mock.Calls[1][0] -ne 'lint' -or $Mock.Calls[-1][0] -ne 'test') { throw 'Wrong validation order' }
    if (($Mock.Calls[-2] -join ' ') -cne 'run --filter ./apps/desktop ensure:electron') { throw 'Initialize the checkout Electron runtime before focused tests' }
    if ((Get-Content $Log -Raw) -notmatch 'PASS: Preflight Electron runtime') { throw 'Missing Electron initialization report' }
    $Typecheck = @($Mock.Calls | Where-Object { $_[0] -eq 'run' -and $_[-1] -eq 'typecheck' })
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
    foreach ($Kind in @('fmt', 'lint', 'typecheck', 'electron', 'test')) {
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
    if ((Get-Content (Join-Path $Root 'preflight.attempt-0006.log') -Raw) -cne $FailedLog) { throw 'Successful retry lost the failed test log' }
    if ((Get-Content (Join-Path $Root 'preflight.attempt-0001.log') -Raw) -notmatch 'PASS: Preflight focused tests') { throw 'Later retries changed an earlier archive' }

    $SplitArguments = ${function:Split-BuildFileArguments}
    function Split-BuildFileArguments {
        param([string[]]$Prefix, [string[]]$Files)
        & $SplitArguments -Prefix $Prefix -Files $Files -MaxCharacters 70
    }
    $Mock.Calls = @()
    Invoke-CustomBuildPreflight -Worktree $Work -BaseRef $Base -LogPath (Join-Path $Root 'batched.log')
    $TestBatches = @($Mock.Calls | Where-Object { $_[0] -eq 'test' })
    $Initializations = @($Mock.Calls | Where-Object { $_[-1] -eq 'ensure:electron' })
    if ($TestBatches.Count -lt 2 -or $Initializations.Count -ne 1) { throw 'Initialize Electron once, not once per focused-test batch' }
    $FirstTest = @($Mock.Calls | ForEach-Object { $_[0] }).IndexOf('test')
    if ($Mock.Calls[$FirstTest - 1][-1] -ne 'ensure:electron') { throw 'Batched tests started before Electron initialization' }
    Set-Item Function:Split-BuildFileArguments $SplitArguments

    $NoTestBase = (git -C $Work rev-parse HEAD).Trim()
    Set-Content "$Work/README.md" 'Documentation-only customization'
    git -C $Work add README.md
    git -C $Work commit -m documentation | Out-Null
    $Mock.Calls = @()
    [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null, 'Process')
    Invoke-CustomBuildPreflight -Worktree $Work -BaseRef $NoTestBase -LogPath (Join-Path $Root 'no-tests.log')
    if ($Mock.Calls.Count -ne 1 -or $Mock.Calls[0][0] -ne 'fmt') { throw 'Scopes without tests must not initialize Electron' }
    if ($env:ELECTRON_RUN_AS_NODE -or (Get-Location).Path -ne $Location) { throw 'An unset harness flag or caller location was not restored' }
    Write-Host 'PASS: scoped checks; single Electron initialization before batches; initialization failure guard; retry logs; environment restoration'
} finally {
    [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $PreviousElectronRunAsNode, 'Process')
    Remove-Item -LiteralPath $Root -Recurse -Force
}
