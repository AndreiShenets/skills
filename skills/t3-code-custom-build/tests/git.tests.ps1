$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '../scripts/git.ps1')
$Root = Join-Path 'C:/Temp/opencode' ("t3-skill-git-test-" + [guid]::NewGuid().ToString('N'))
$Origin = Join-Path $Root 'origin.git'
$Repo = Join-Path $Root 'repo'
$Occupied = Join-Path $Root 'occupied'
$Scratch = Join-Path $Root 'scratch'
New-Item -ItemType Directory -Path $Root, $Scratch | Out-Null

function Commit-File([string]$Path, [string]$Name) {
    Set-Content (Join-Path $Path $Name) $Name
    git -C $Path add -- $Name
    git -C $Path commit -m $Name | Out-Null
}

try {
    git init --bare --initial-branch=main $Origin | Out-Null
    git init --initial-branch=main $Repo | Out-Null
    git -C $Repo config user.name 'Skill Test'
    git -C $Repo config user.email 'skill-test@example.invalid'
    git -C $Repo config commit.gpgsign false
    git -C $Repo config core.hooksPath (Join-Path $Root 'empty-hooks')
    Commit-File $Repo 'base.txt'
    git -C $Repo remote add origin $Origin
    git -C $Repo push -u origin main | Out-Null
    git -C $Repo branch customizations/occupied
    git -C $Repo branch customizations/remote-only
    git -C $Repo push origin customizations/occupied customizations/remote-only | Out-Null
    git -C $Repo branch -d customizations/remote-only | Out-Null
    git -C $Repo worktree add $Occupied customizations/occupied | Out-Null
    Commit-File $Occupied 'custom.txt'
    Commit-File $Repo 'main.txt'
    git -C $Repo push origin main | Out-Null
    $Main = (git -C $Repo rev-parse main).Trim()

    Merge-TrackedBranch -Repo $Repo -Branch main -MergeRef origin/main -Scratch $Scratch -FastForwardOnly
    Merge-TrackedBranch -Repo $Repo -Branch customizations/occupied -MergeRef $Main -Scratch $Scratch
    if (!(Test-Path (Join-Path $Occupied 'custom.txt')) -or !(Test-Path (Join-Path $Occupied 'main.txt'))) {
        throw 'Existing worktree lost main or customization content'
    }
    Merge-TrackedBranch -Repo $Repo -Branch customizations/remote-only -MergeRef $Main -Scratch $Scratch
    git -C $Repo merge-base --is-ancestor $Main customizations/remote-only
    if ((@(git -C $Repo worktree list --porcelain | Where-Object { $_ -like 'worktree *' })).Count -ne 2) {
        throw 'Temporary worktree was not removed, or borrowed worktree was removed'
    }

    $Before = (git -C $Occupied rev-parse HEAD).Trim()
    Set-Content (Join-Path $Occupied 'user-work.txt') 'preserve'
    $Blocked = $false
    try {
        Merge-TrackedBranch -Repo $Repo -Branch customizations/occupied -MergeRef $Main -Scratch $Scratch
    } catch {
        if ($_.Exception.Message -notlike 'Dirty worktree:*') { throw }
        $Blocked = $true
    }
    if (!$Blocked -or (git -C $Occupied rev-parse HEAD).Trim() -ne $Before) { throw 'Dirty-worktree guard failed' }
    if ((Get-Content (Join-Path $Occupied 'user-work.txt')) -ne 'preserve') { throw 'User work changed' }
    Remove-Item -LiteralPath (Join-Path $Occupied 'user-work.txt')

    Set-Content (Join-Path $Repo 'base.txt') 'main change'
    git -C $Repo commit -am main-change | Out-Null
    git -C $Repo push origin main | Out-Null
    $NewMain = (git -C $Repo rev-parse main).Trim()
    Set-Content (Join-Path $Occupied 'base.txt') 'custom change'
    git -C $Occupied commit -am custom-change | Out-Null
    $RemoteBefore = (git -C $Origin rev-parse refs/heads/customizations/occupied).Trim()
    $Conflicted = $false
    try {
        Merge-TrackedBranch -Repo $Repo -Branch customizations/occupied -MergeRef $NewMain -Scratch $Scratch
    } catch { $Conflicted = $true }
    if (!$Conflicted) { throw 'Conflicting merge did not stop' }
    git -C $Occupied rev-parse --verify MERGE_HEAD | Out-Null
    if ((git -C $Origin rev-parse refs/heads/customizations/occupied).Trim() -ne $RemoteBefore) {
        throw 'Conflicted branch was pushed'
    }

    Commit-File $Repo 'local-main-only.txt'
    $AheadBlocked = $false
    try {
        Merge-TrackedBranch -Repo $Repo -Branch main -MergeRef origin/main -Scratch $Scratch -FastForwardOnly
    } catch {
        if ($_.Exception.Message -notlike 'Local main is ahead*') { throw }
        $AheadBlocked = $true
    }
    if (!$AheadBlocked -or (git -C $Origin rev-parse main).Trim() -ne $NewMain) { throw 'Ahead-main guard failed' }
    Write-Host 'PASS: main sync; occupied/remote-only branches; push; cleanup; dirty/conflict/ahead-main guards'
} finally {
    # Only this test's newly created fixture is removed.
    Remove-Item -LiteralPath $Root -Recurse -Force
}
