$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '../scripts/git.ps1')
. (Join-Path $PSScriptRoot '../scripts/progress.ps1')
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-skill-recovery-test-" + [guid]::NewGuid().ToString('N'))
$Repo = Join-Path $Root 'repo'
$Origin = Join-Path $Root 'origin.git'
$A = Join-Path $Root 'a'
$B = Join-Path $Root 'b'
$Scratch = Join-Path $Root 'run'
$Build = Join-Path $Scratch 'build'
$Run = Join-Path $Scratch 'run.json'
$Workflow = Join-Path $PSScriptRoot '../scripts/workflow.ps1'
New-Item -ItemType Directory -Path $Root, $Scratch | Out-Null

function Commit-All([string]$Path, [string]$Message) {
    git -C $Path add .
    git -C $Path commit -m $Message | Out-Null
}

function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure: $Pattern"
}

try {
    git init --bare --initial-branch=main $Origin | Out-Null
    git init --initial-branch=main $Repo | Out-Null
    git -C $Repo config user.name 'Skill Test'
    git -C $Repo config user.email 'skill-test@example.invalid'
    git -C $Repo config commit.gpgsign false
    git -C $Repo config core.hooksPath (Join-Path $Root 'empty-hooks')
    Set-Content (Join-Path $Repo 'collision.txt') 'base'
    Commit-All $Repo base
    git -C $Repo remote add origin $Origin
    git -C $Repo worktree add -b customizations/a $A main | Out-Null
    git -C $Repo worktree add -b customizations/b $B main | Out-Null
    Set-Content (Join-Path $A 'shared.txt') 'A'
    Commit-All $A customization-a
    Set-Content (Join-Path $B 'shared.txt') 'B'
    Set-Content (Join-Path $B 'collision.txt') 'customization'
    Commit-All $B customization-b
    Set-Content (Join-Path $Repo 'collision.txt') 'main'
    Commit-All $Repo main-change
    git -C $Repo push origin main customizations/a customizations/b | Out-Null
    $Main = (git -C $Repo rev-parse HEAD).Trim()

    # A hook that would fail any ordinary merge/resolution commit must never run in this workflow.
    $Hooks = Join-Path $Root 'failing-hooks'
    New-Item -ItemType Directory -Path $Hooks | Out-Null
    foreach ($Hook in @('pre-commit', 'pre-merge-commit')) {
        [IO.File]::WriteAllText((Join-Path $Hooks $Hook), "#!/bin/sh`nexit 73`n")
    }
    git -C $Repo config core.hooksPath $Hooks
    @{
        Repo = $Repo; Scratch = $Scratch; MainSha = $Main; Branches = @()
        Customizations = @{}; BuildBranch = 'custom_builds/2026_10_17_19_01'; Work = $Build; Merged = $false
    } | ConvertTo-Json | Set-Content $Run

    $Lock = [IO.File]::Open("$Run.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    try { Expect-Failure { & $Workflow -Stage Merge -Run $Run } 'Run is already active*' }
    finally { $Lock.Dispose() }

    Expect-Failure { & $Workflow -Stage Merge -Run $Run } '*'
    $Saved = Get-Content $Run -Raw | ConvertFrom-Json -AsHashtable
    if ($Saved.Customizations.Count -ne 1 -or !$Saved.Customizations.ContainsKey('customizations/a')) {
        throw 'A completed branch was not checkpointed before the next conflict'
    }
    $AHead = (git -C $A rev-parse HEAD).Trim()
    Set-Content (Join-Path $A 'user-work.txt') 'untouched work in a completed branch'
    $Record = Join-Path $Scratch 'pending-merge.json'
    $Pending = Get-Content $Record -Raw | ConvertFrom-Json
    $BeforeB = $Pending.Before
    Expect-Failure { & $Workflow -Stage Merge -Run $Run } 'Resolve and stage conflicts*'
    git -C $B add collision.txt
    Expect-Failure { Complete-PendingMerge -Scratch $Scratch } '*'
    if ((git -C $B rev-parse HEAD).Trim() -ne $BeforeB) { throw 'Leftover conflict markers were committed' }
    Set-Content (Join-Path $B 'collision.txt') 'main + customization'
    git -C $B add collision.txt
    # Reproduce the lost MERGE_HEAD left by the failed Windows pre-commit recovery.
    git -C $B merge --quit
    Expect-Failure { git -C $B rev-parse --verify MERGE_HEAD } '*'

    Expect-Failure { & $Workflow -Stage Merge -Run $Run } '*'
    $BParents = (git -C $B rev-list --parents -n 1 HEAD) -split ' '
    if ($BParents.Count -ne 3 -or $BParents[1] -ne $BeforeB -or $BParents[2] -ne $Main) { throw 'Lost merge parents were not restored' }
    if ((Get-Content (Join-Path $B 'collision.txt')) -ne 'main + customization') { throw 'Staged resolution was changed' }
    if ((git -C $A rev-parse HEAD).Trim() -ne $AHead -or !(Test-Path (Join-Path $A 'user-work.txt'))) {
        throw 'Resume revisited or changed a completed customization'
    }
    $Saved = Get-Content $Run -Raw | ConvertFrom-Json -AsHashtable
    if ($Saved.Customizations.Count -ne 2 -or $Saved.Integrated.Count -ne 1) { throw 'Integration progress was not checkpointed' }

    # A mistakenly made snapshot commit must be preserved, then gain a real merge parent without force-pushing.
    $Pending = Get-Content $Record -Raw | ConvertFrom-Json
    if ([IO.Path]::GetFullPath($Pending.Path) -ne [IO.Path]::GetFullPath($Build)) { throw 'Wrong integration recovery path' }
    Set-Content (Join-Path $Build 'shared.txt') 'A + B'
    git -C $Build add shared.txt
    git -C $Build merge --quit
    git -C $Build -c "core.hooksPath=$(Join-Path $Root 'empty-hooks')" commit -m snapshot-resolution | Out-Null
    $Snapshot = (git -C $Build rev-parse HEAD).Trim()
    $Tree = (git -C $Build rev-parse 'HEAD^{tree}').Trim()
    & $Workflow -Stage Merge -Run $Run
    $Parents = (git -C $Build rev-list --parents -n 1 HEAD) -split ' '
    if ($Parents.Count -ne 3 -or $Parents[1] -ne $Snapshot -or $Parents[2] -ne $Pending.Target) { throw 'Snapshot recovery lost history or merge ancestry' }
    if ((git -C $Build rev-parse 'HEAD^{tree}').Trim() -ne $Tree) { throw 'Snapshot recovery changed resolved files' }
    $Saved = Get-Content $Run -Raw | ConvertFrom-Json -AsHashtable
    if (!$Saved.Merged -or $Saved.Integrated.Count -ne 2 -or (Test-Path $Record)) { throw 'Resume did not finish durably' }
    foreach ($Sha in $Saved.Customizations.Values) { git -C $Build merge-base --is-ancestor $Sha HEAD }
    if ((git -C $Origin rev-parse $Saved.BuildBranch).Trim() -ne (git -C $Build rev-parse HEAD).Trim()) { throw 'Recovered integration was not pushed' }
    if ((git -C $Repo config core.hooksPath) -ne $Hooks) { throw 'Workflow changed persistent hook configuration' }
    Assert-Clean $Build

    # A crash after updating HEAD but before clearing MERGE_HEAD must finish cleanup on the next invocation.
    @{
        Path = $Build; Target = $Pending.Target; Before = $Snapshot; Branch = $Saved.BuildBranch; Label = 'post-commit cleanup'
    } | ConvertTo-Json | Set-Content $Record
    $MergeHead = (git -C $Build rev-parse --path-format=absolute --git-path MERGE_HEAD).Trim()
    Set-Content $MergeHead $Pending.Target
    Complete-PendingMerge -Scratch $Scratch
    if ((Test-Path $MergeHead) -or (Test-Path $Record)) { throw 'Completed merge metadata was left behind after recovery' }

    # An aborted/no-op resolution must not silently create a merge that discards the target's changes.
    @{
        Path = $Repo; Target = $Saved.Customizations['customizations/b']; Before = $Main; Branch = 'main'; Label = 'aborted fixture'
    } | ConvertTo-Json | Set-Content $Record
    Expect-Failure { Complete-PendingMerge -Scratch $Scratch } 'Pending merge has no staged resolution*'
    if ((git -C $Repo rev-parse HEAD).Trim() -ne $Main) { throw 'Aborted merge recovery moved HEAD' }

    if ((Get-BuildCacheDirectory $Repo) -ne (Get-BuildCacheDirectory $Build)) { throw 'Worktrees do not share the repository cache' }
    Write-Host 'PASS: hook isolation; lost metadata and snapshot recovery; verified parents; per-branch/integration resume; borrowed work preserved; abort guard; shared cache'
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
