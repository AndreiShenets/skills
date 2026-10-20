$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-tooling-test-" + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot '../scripts/tooling.ps1')
try {
    foreach ($Name in @('work space', 'bootstrap')) {
        $Package = Join-Path $Root "$Name/node_modules/vite-plus"
        New-Item -ItemType Directory -Path "$Package/bin" -Force | Out-Null
        Set-Content "$Package/package.json" '{"bin":{"vp":"bin/custom-cli.cjs"}}'
        Set-Content "$Package/bin/custom-cli.cjs" 'console.log(JSON.stringify({cli:__filename,args:process.argv.slice(2)}))'
    }
    $Work = Join-Path $Root 'work space'
    $Repo = Join-Path $Root 'bootstrap'
    $Arguments = @('install', '--frozen-lockfile', '--', '--store-dir', 'C:\cache with spaces\store')
    $Result = Invoke-WorktreeVp -Worktree $Work -BootstrapRepo $Repo -Arguments $Arguments | ConvertFrom-Json
    if (!$Result.cli.Contains('work space') -or ($Result.args -join '|') -cne ($Arguments -join '|')) { throw 'Worktree selection or pass-through arguments changed' }
    $Arguments = @('fmt', "single ' and double `" quotes.ts", '日本語.ts')
    $Expected = $Arguments -join '|'
    $Result = Invoke-WorktreeVp -Worktree $Work -Arguments $Arguments | ConvertFrom-Json
    if (($Result.args -join '|') -cne $Expected) { throw 'Quoted/unicode paths changed' }
    $Files = @(1..250 | ForEach-Object { "src/folder with spaces/$_/$('x' * 100).test.ts" })
    $Received = @()
    $Batches = @(Split-BuildFileArguments -Prefix @('test', 'run') -Files $Files)
    foreach ($Batch in $Batches) {
        if (($Batch.Arguments -join ' ').Length -gt 7000) { throw 'Oversized argument batch' }
        $Result = Invoke-WorktreeVp -Worktree $Work -Arguments $Batch.Arguments | ConvertFrom-Json
        $Received += $Result.args | Select-Object -Skip 2
    }
    if ($Batches.Count -lt 2 -or ($Received -join '|') -cne ($Files -join '|')) { throw 'Batching lost or reordered paths' }
    if (@(Split-BuildFileArguments -Prefix @('test', 'run') -Files @()).Count) { throw 'Empty scope became a repo-wide check' }
    $Missing = Join-Path $Root 'uninstalled'
    $Result = Invoke-WorktreeVp -Worktree $Missing -BootstrapRepo $Repo -Arguments @('install', '--') | ConvertFrom-Json
    if (!$Result.cli.Contains('bootstrap')) { throw 'First install did not use the explicit repository bootstrap' }
    $Blocked = $false
    try { Invoke-WorktreeVp -Worktree $Missing -BootstrapRepo $Repo -Arguments @('test', 'run') } catch { $Blocked = $true }
    if (!$Blocked) { throw 'Checks used another checkout runtime' }
    Write-Host 'PASS: real Node invocation; local runtime isolation; literal separator; quotes/unicode; bounded long file lists; first-install bootstrap'
} finally { Remove-Item -LiteralPath $Root -Recurse -Force }
