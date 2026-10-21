$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '../scripts/progress.ps1')
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-skill-storage-test-" + [guid]::NewGuid().ToString('N'))
$Repo = Join-Path $Root 'repo'
$Linked = Join-Path $Root 'linked'
$Data = Join-Path $Repo 'release/as-custom'
$Workflow = Join-Path $PSScriptRoot '../scripts/workflow.ps1'

# Stop after the real Sync initialization, before any network or branch changes.
function gh {
    if ($args.Count -ne 2 -or $args[0] -ne 'auth' -or $args[1] -ne 'status') { throw 'Unexpected GitHub command' }
    throw 'Fixture: stop before network access'
}

try {
    git init --initial-branch=main $Repo | Out-Null
    git -C $Repo config user.name 'Skill Test'
    git -C $Repo config user.email 'skill-test@example.invalid'
    git -C $Repo config commit.gpgsign false
    git -C $Repo config core.hooksPath (Join-Path $Root 'empty-hooks')
    Set-Content (Join-Path $Repo 'base.txt') 'base'
    Set-Content (Join-Path $Repo '.gitignore') 'release/'
    git -C $Repo add base.txt .gitignore
    git -C $Repo commit -m fixture | Out-Null
    git -C $Repo remote add origin https://github.com/AndreiShenets/t3code.git
    git -C $Repo worktree add -b fixture $Linked | Out-Null

    foreach ($Checkout in @($Repo, $Linked)) {
        $Stopped = $false
        try { & $Workflow -Stage Sync -Repo $Checkout } catch {
            if ($_.Exception.Message -ne 'Fixture: stop before network access') { throw }
            $Stopped = $true
        }
        if (!$Stopped) { throw 'Sync did not stop at the network boundary' }
    }
    $Runs = @(Get-ChildItem -LiteralPath (Join-Path $Data 'runs') -Filter run.json -Recurse -ErrorAction SilentlyContinue)
    if ($Runs.Count -ne 2) { throw 'Sync did not create run state under release/as-custom for both checkouts' }
    foreach ($Run in $Runs) {
        $Saved = Get-Content -LiteralPath $Run.FullName -Raw | ConvertFrom-Json -AsHashtable
        if ($Saved.Scratch -ne $Run.DirectoryName) { throw 'Saved scratch directory disagrees with run.json location' }
        if ($Saved.Cache -ne (Join-Path $Data 'cache')) { throw 'Shared cache is not under release/as-custom' }
        if ($Saved.Work -ne (Join-Path $Data $Run.Directory.Name)) { throw 'Build worktree is not under release/as-custom' }
        if (!(Test-Path -LiteralPath "$($Run.FullName).lock")) { throw 'Run lock is not beside run.json' }
    }
    New-Item -ItemType Directory -Path $Saved.Cache | Out-Null
    Set-Content (Join-Path $Saved.Cache 'sentinel') 'cache'
    git -C $Repo worktree add -b fixture-build $Saved.Work | Out-Null
    if ((Get-BuildDataDirectory $Saved.Work) -ne $Data) { throw 'Nested build checkout changed the shared data root' }
    $MergeWorktree = Join-Path $Saved.Scratch 'merge-fixture'
    git -C $Repo worktree add -b fixture-merge $MergeWorktree | Out-Null
    if ((Get-BuildDataDirectory $MergeWorktree) -ne $Data) { throw 'Nested merge checkout changed the shared data root' }
    if ((Get-BuildCacheDirectory $Repo) -ne (Get-BuildCacheDirectory $Linked)) { throw 'Linked checkout changed the shared cache root' }
    if (Test-Path -LiteralPath (Join-Path $Repo '.git/as-custom')) { throw 'New run data was written inside Git metadata' }
    if (Test-Path -LiteralPath (Join-Path $Root 'repo-as-custom')) { throw 'New run data was written beside the repository' }
    if (git -C $Repo status --porcelain) { throw 'Run initialization dirtied the source checkout' }
    if (git -C $Linked status --porcelain) { throw 'Run initialization dirtied the linked checkout' }
    if (git -C $Saved.Work status --porcelain) { throw 'Nested build checkout is dirty' }
    if (git -C $MergeWorktree status --porcelain) { throw 'Nested merge checkout is dirty' }

    # Existing runs retain their recorded paths; never move/delete their recovery data implicitly.
    $LegacyScratch = Join-Path $Repo '.git/as-custom/runs/legacy'
    $LegacyCache = Join-Path $Repo '.git/as-custom/cache'
    New-Item -ItemType Directory -Path $LegacyScratch, $LegacyCache | Out-Null
    Set-Content (Join-Path $LegacyScratch 'build.log') 'retained log'
    Set-Content (Join-Path $LegacyCache 'sentinel') 'retained cache'
    $LegacyRun = Join-Path $LegacyScratch 'run.json'
    @{
        Repo = $Repo; Scratch = $LegacyScratch; Cache = $LegacyCache; Work = $Linked
        MainSha = (git -C $Repo rev-parse HEAD).Trim(); Merged = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $LegacyRun
    $Before = Get-Content -LiteralPath $LegacyRun -Raw
    & $Workflow -Stage Merge -Run $LegacyRun
    if ((Get-Content -LiteralPath $LegacyRun -Raw) -cne $Before) { throw 'Existing run paths were rewritten' }
    if ((Get-Content (Join-Path $LegacyScratch 'build.log')) -ne 'retained log' -or
        (Get-Content (Join-Path $LegacyCache 'sentinel')) -ne 'retained cache') { throw 'Legacy recovery data was changed' }
    Write-Host 'PASS: ignored release storage; shared data root for main/linked/nested checkouts; clean checkouts; legacy data preserved'
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
