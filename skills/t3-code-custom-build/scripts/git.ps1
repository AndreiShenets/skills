$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Assert-Clean {
    param([Parameter(Mandatory)][string]$Path)
    if (git -C $Path status --porcelain) { throw "Dirty worktree: $Path" }
}

function Merge-TrackedBranch {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$MergeRef,
        [Parameter(Mandatory)][string]$Scratch,
        [switch]$FastForwardOnly
    )
    $Path = $null
    $Candidate = $null
    foreach ($Line in (git -C $Repo -c core.quotepath=false worktree list --porcelain)) {
        if ($Line.StartsWith('worktree ')) { $Candidate = $Line.Substring(9) }
        if ($Line -ceq "branch refs/heads/$Branch") { $Path = $Candidate; break }
    }
    $Created = !$Path
    if ($Created) {
        $Path = Join-Path $Scratch ([guid]::NewGuid().ToString('N'))
        $Local = git -C $Repo for-each-ref '--format=%(refname)' "refs/heads/$Branch"
        if ($Local -ccontains "refs/heads/$Branch") {
            git -C $Repo worktree add $Path $Branch
        } else {
            $Remote = git -C $Repo for-each-ref '--format=%(refname)' "refs/remotes/origin/$Branch"
            if ($Remote -cnotcontains "refs/remotes/origin/$Branch") { throw "Missing branch: $Branch" }
            git -C $Repo worktree add --track -b $Branch $Path "origin/$Branch"
        }
    }
    Write-Host "$Branch => $Path"
    Assert-Clean $Path
    if ((git -C $Path symbolic-ref --short HEAD).Trim() -cne $Branch) { throw 'Branch changed' }
    if ($FastForwardOnly) {
        git -C $Path merge --ff-only $MergeRef
        if ((git -C $Path rev-parse HEAD).Trim() -ne (git -C $Path rev-parse $MergeRef).Trim()) {
            throw "Local $Branch is ahead of $MergeRef; reconcile before pushing"
        }
    } else {
        $Remote = git -C $Repo for-each-ref '--format=%(refname)' "refs/remotes/origin/$Branch"
        if ($Remote -ccontains "refs/remotes/origin/$Branch") {
            git -C $Path merge --no-edit "origin/$Branch"
        }
        git -C $Path merge --no-edit $MergeRef
    }
    git -C $Path merge-base --is-ancestor $MergeRef HEAD
    Assert-Clean $Path
    git -C $Path push --set-upstream origin $Branch
    if ($Created) { git -C $Repo worktree remove $Path }
}
