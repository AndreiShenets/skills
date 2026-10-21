. (Join-Path $PSScriptRoot 'progress.ps1')

function Get-OverlapPolicyHash {
    $Inputs = @('overlap-ledger-v1')
    foreach ($Path in @('overlap-cache.ps1', 'overlap.ps1', '../SKILL.md', '../references/release-notes.md')) {
        $Inputs += (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $Path) -Algorithm SHA256).Hash
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Inputs -join "`n"))))
}

function Test-OverlapAncestor {
    param([string]$Repo, [string]$Before, [string]$After)
    if ($Before -notmatch '^[a-f0-9]{40}$') { return $false }
    $PSNativeCommandUseErrorActionPreference = $false
    git -C $Repo cat-file -e "$Before^{commit}" 2>$null
    if ($LASTEXITCODE) { return $false }
    git -C $Repo merge-base --is-ancestor $Before $After
    $LASTEXITCODE -eq 0
}

function Get-OverlapReviewPlan {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$UpstreamSha,
        [Parameter(Mandatory)][string]$NightlyTag,
        [Parameter(Mandatory)][string]$PublishedSha
    )
    $Record = Join-Path (Get-BuildCacheDirectory $Repo) 'overlap/findings.json'
    $Saved = $null
    try {
        $Saved = Get-Content -LiteralPath $Record -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        if ($Saved.schema -ne 1 -or !$Saved.customizations.Count -or
            @($Saved.customizations.branch | Sort-Object -Unique).Count -ne $Saved.customizations.Count) { $Saved = $null }
    } catch { $Saved = $null }
    $PolicyHash = Get-OverlapPolicyHash
    $Scope = 'full'
    $Commits = @(); $ChangedFiles = @(); $PublishedFiles = @()
    if ($Saved -and $Saved.policyHash -ceq $PolicyHash -and
        (Test-OverlapAncestor $Repo $Saved.upstreamSha $UpstreamSha) -and
        (Test-OverlapAncestor $Repo $Saved.publishedSha $PublishedSha)) {
        $Scope = 'delta'
        $Commits = @(git -C $Repo log '--format=%H %s' "$($Saved.upstreamSha)..$UpstreamSha")
        $ChangedFiles = @(git -C $Repo -c core.quotepath=false diff --name-only $Saved.upstreamSha $UpstreamSha)
        $PublishedFiles = @(git -C $Repo -c core.quotepath=false diff --name-only $Saved.publishedSha $PublishedSha)
        if ($Saved.upstreamSha -ceq $UpstreamSha -and $Saved.publishedSha -ceq $PublishedSha -and $Saved.nightlyTag -ceq $NightlyTag) { $Scope = 'unchanged' }
    }
    $Rows = @(foreach ($Branch in @(git -C $Repo for-each-ref '--format=%(refname)' refs/remotes/origin/customizations/ | Sort-Object)) {
        $Name = $Branch -replace '^refs/remotes/origin/', ''
        $Sha = (git -C $Repo rev-parse "$Branch^{commit}").Trim()
        $Previous = @($Saved.customizations | Where-Object branch -CEQ $Name | Select-Object -First 1)
        $CustomScope = if ($Previous.Count -ne 1 -or $Previous[0].sha -cne $Sha) { 'full' } else { $Scope }
        @{
            branch = $Name; sha = $Sha; scope = $CustomScope
            # Evidence is a research hint, never an approval or a ready-to-publish finding.
            previous = if ($Previous.Count) { $Previous[0] } else { $null }
        }
    })
    if (!$Rows.Count) { throw 'No fetched remote customizations found; fetch origin customizations/* first' }
    @{
        schema = 1; upstreamSha = $UpstreamSha; nightlyTag = $NightlyTag; publishedSha = $PublishedSha
        policyHash = $PolicyHash; requiresVerification = $true; scope = $Scope
        previousUpstreamSha = if ($Saved) { $Saved.upstreamSha } else { $null }
        previousPublishedSha = if ($Saved) { $Saved.publishedSha } else { $null }
        previousCheckedAt = if ($Saved) { $Saved.checkedAt } else { $null }
        upstreamCommits = $Commits; upstreamChangedFiles = $ChangedFiles; publishedChangedFiles = $PublishedFiles
        customizations = $Rows
    }
}

function Save-OverlapFindings {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$UpstreamSha,
        [Parameter(Mandatory)][string]$NightlyTag,
        [Parameter(Mandatory)][string]$PublishedSha,
        [Parameter(Mandatory)][string]$FindingsFile
    )
    $Findings = Get-Content -LiteralPath $FindingsFile -Raw | ConvertFrom-Json -AsHashtable
    if ($Findings.upstreamSha -cne $UpstreamSha -or $Findings.nightlyTag -cne $NightlyTag) { throw 'Cache findings disagree with the reviewed upstream inputs' }
    $Rows = @($Findings.customizations)
    if (!$Rows.Count -or @($Rows.branch | Sort-Object -Unique).Count -ne $Rows.Count) { throw 'Duplicate or empty cached findings' }
    $RemoteNames = @(git -C $Repo for-each-ref '--format=%(refname:strip=3)' refs/remotes/origin/customizations/)
    foreach ($Name in $RemoteNames) {
        if ($Name -cnotin $Rows.branch) { throw "Missing cached findings: $Name" }
    }
    $Sanitized = @(foreach ($Row in $Rows) {
        if ($Row.branch -notmatch '^customizations/[\w./-]+$' -or $Row.sha -notmatch '^[a-f0-9]{40}$' -or
            $Row.coverage -cnotin @('full', 'partial', 'absent', 'unreleased', 'unverified') -or
            [string]::IsNullOrWhiteSpace($Row.description) -or [string]::IsNullOrWhiteSpace($Row.finding) -or !$Row.evidence.Count) {
            throw 'Invalid overlap cache entry'
        }
        # Whitelist fields: per-run dispositions and human decisions never cross runs.
        @{
            branch = $Row.branch; sha = $Row.sha; description = $Row.description
            coverage = $Row.coverage; finding = $Row.finding
            evidence = @($Row.evidence | ForEach-Object { @{ label = $_.label; url = $_.url } })
        }
    })
    $Directory = Join-Path (Get-BuildCacheDirectory $Repo) 'overlap'
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $Record = Join-Path $Directory 'findings.json'
    $Temporary = "$Record.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Lock = [IO.File]::Open("$Record.lock", 'OpenOrCreate', 'ReadWrite', 'None')
        @{
            schema = 1; policyHash = Get-OverlapPolicyHash; checkedAt = (Get-Date).ToString('o')
            upstreamSha = $UpstreamSha; nightlyTag = $NightlyTag; publishedSha = $PublishedSha
            customizations = $Sanitized
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Temporary -Encoding utf8NoBOM
        [IO.File]::Move($Temporary, $Record, $true)
    } finally {
        if ($Lock) { $Lock.Dispose() }
        if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary }
    }
    $Record
}
