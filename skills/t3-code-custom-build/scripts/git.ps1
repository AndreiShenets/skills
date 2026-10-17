$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Assert-Clean {
    param([Parameter(Mandatory)][string]$Path)
    if (git -C $Path status --porcelain) { throw "Dirty worktree: $Path" }
}

function Get-RemoteCustomizationBranches {
    param([Parameter(Mandatory)][string]$Repo)
    git -C $Repo fetch origin --prune '+refs/heads/main:refs/remotes/origin/main' '+refs/heads/customizations/*:refs/remotes/origin/customizations/*' | Out-Host
    @(git -C $Repo for-each-ref '--format=%(refname)' refs/remotes/origin/customizations/ |
        ForEach-Object { $_ -replace '^refs/remotes/origin/', '' } | Sort-Object -Unique)
}

function Test-Ancestor {
    param([string]$Path, [string]$Ancestor, [string]$Descendant = 'HEAD')
    $PSNativeCommandUseErrorActionPreference = $false
    git -C $Path merge-base --is-ancestor $Ancestor $Descendant
    if ($LASTEXITCODE -notin @(0, 1)) { throw 'Cannot inspect merge ancestry' }
    return $LASTEXITCODE -eq 0
}

function Complete-PendingMerge {
    param([Parameter(Mandatory)][string]$Scratch)
    $Record = Join-Path $Scratch 'pending-merge.json'
    if (!(Test-Path -LiteralPath $Record)) { return }
    $Pending = Get-Content -LiteralPath $Record -Raw | ConvertFrom-Json
    $Path = $Pending.Path
    if ((git -C $Path symbolic-ref --short HEAD).Trim() -cne $Pending.Branch) { throw 'Pending merge branch changed' }
    if (git -C $Path ls-files --unmerged) {
        throw "Resolve and stage conflicts in $Path, validate the resolution, then rerun this stage. Pending merge: $Record"
    }
    if ((git -C $Path diff --name-only) -or (git -C $Path ls-files --others --exclude-standard)) {
        throw "Stage the complete resolution in $Path before resuming"
    }
    $Head = (git -C $Path rev-parse HEAD).Trim()
    if (!(Test-Ancestor $Path $Pending.Before $Head)) { throw 'Pending merge history changed' }
    $MergeHeadPath = (git -C $Path rev-parse --path-format=absolute --git-path MERGE_HEAD).Trim()
    $HasMergeHead = Test-Path -LiteralPath $MergeHeadPath
    if ($HasMergeHead -and (Get-Content -LiteralPath $MergeHeadPath -Raw).Trim() -ne $Pending.Target) {
        throw 'Pending merge target changed'
    }
    if (Test-Ancestor $Path $Pending.Target $Head) {
        Assert-Clean $Path
    } else {
        # Upstream patch files can contain intentional trailing spaces; reject leftover conflict markers, not imported whitespace.
        git -C $Path -c 'core.whitespace=-blank-at-eol,-blank-at-eof,-space-before-tab' diff --cached --check
        # commit-tree uses the staged resolution and frozen parents even if a failed hook erased MERGE_HEAD.
        $Tree = (git -C $Path write-tree).Trim()
        if (!$HasMergeHead -and $Head -eq $Pending.Before -and $Tree -eq (git -C $Path rev-parse 'HEAD^{tree}').Trim()) {
            throw 'Pending merge has no staged resolution; it may have been aborted'
        }
        $Commit = (git -C $Path commit-tree $Tree -p $Head -p $Pending.Target -m "Merge $($Pending.Label)").Trim()
        git -C $Path update-ref HEAD $Commit $Head
        Assert-Clean $Path
        $Parents = ((git -C $Path rev-list --parents -n 1 HEAD) -split ' ')
        if ($Parents.Count -ne 3 -or $Parents[1] -ne $Head -or $Parents[2] -ne $Pending.Target) { throw 'Merge parents do not match recorded inputs' }
    }
    git -C $Path merge --quit
    Remove-Item -LiteralPath $Record
    Write-Host "Verified merge: $($Pending.Label) => $Path"
}

function Merge-VerifiedRef {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MergeRef,
        [Parameter(Mandatory)][string]$Scratch,
        [string]$Label = $MergeRef
    )
    if (Test-Path (Join-Path $Scratch 'pending-merge.json')) { throw 'Resume the pending merge before starting another' }
    Assert-Clean $Path
    $Target = (git -C $Path rev-parse "$MergeRef^{commit}").Trim()
    if (Test-Ancestor $Path $Target) { return }
    $Record = Join-Path $Scratch 'pending-merge.json'
    @{
        Path = $Path; Target = $Target; Before = (git -C $Path rev-parse HEAD).Trim()
        Branch = (git -C $Path symbolic-ref --short HEAD).Trim(); Label = $Label
    } | ConvertTo-Json | Set-Content -LiteralPath $Record -Encoding utf8NoBOM
    Write-Host "Merging $Label => $Path (recovery: $Record)"
    # Imported upstream files are already formatted; repository hooks would reformat the entire merge.
    git -C $Path -c "core.hooksPath=$(Join-Path $Scratch 'no-hooks')" merge --no-edit $Target | Out-Host
    Complete-PendingMerge -Scratch $Scratch
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
    if ($Path) { Assert-Clean $Path }
    $Local = @(git -C $Repo for-each-ref '--format=%(refname)' "refs/heads/$Branch")
    if ($Local -ccontains "refs/heads/$Branch" -and (Test-Ancestor $Repo $MergeRef $Branch)) {
        $Remote = @(git -C $Repo for-each-ref '--format=%(refname)' "refs/remotes/origin/$Branch")
        if ($Remote -ccontains "refs/remotes/origin/$Branch" -and (Test-Ancestor $Repo "origin/$Branch" $Branch)) {
            if ($FastForwardOnly -and (git -C $Repo rev-parse $Branch).Trim() -ne (git -C $Repo rev-parse $MergeRef).Trim()) {
                throw "Local $Branch is ahead of $MergeRef; reconcile before pushing"
            }
            git -C $Repo push --set-upstream origin $Branch | Out-Host
            return
        }
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
            Merge-VerifiedRef -Path $Path -MergeRef "origin/$Branch" -Scratch $Scratch -Label "origin/$Branch"
        }
        Merge-VerifiedRef -Path $Path -MergeRef $MergeRef -Scratch $Scratch -Label "$MergeRef into $Branch"
    }
    git -C $Path merge-base --is-ancestor $MergeRef HEAD
    Assert-Clean $Path
    git -C $Path push --set-upstream origin $Branch
    if ($Created) { git -C $Repo worktree remove $Path }
}
