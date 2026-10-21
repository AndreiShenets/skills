$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '../scripts/overlap-cache.ps1')
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-overlap-test-" + [guid]::NewGuid().ToString('N'))
$Repo = Join-Path $Root 'main repo'
$Linked = Join-Path $Root 'linked'
try {
    git init --initial-branch=main $Repo | Out-Null
    git -C $Repo config user.name 'Skill Test'
    git -C $Repo config user.email 'skill-test@example.invalid'
    git -C $Repo config commit.gpgsign false
    git -C $Repo config core.hooksPath (Join-Path $Root 'no-hooks')
    Set-Content (Join-Path $Repo '.gitignore') 'release/'
    Set-Content (Join-Path $Repo 'feature.txt') 'base'
    git -C $Repo add .
    git -C $Repo commit -m base | Out-Null
    $Base = (git -C $Repo rev-parse HEAD).Trim()
    git -C $Repo update-ref refs/remotes/origin/customizations/fixture $Base
    git -C $Repo worktree add -b fixture $Linked | Out-Null
    $Inputs = @{ Repo = $Repo; UpstreamSha = $Base; NightlyTag = 'v0.1.1-nightly.1'; PublishedSha = $Base }
    $Cold = Get-OverlapReviewPlan @Inputs
    if ($Cold.scope -ne 'full' -or $Cold.customizations[0].scope -ne 'full' -or !$Cold.requiresVerification) { throw 'Cold cache did not request full verification' }
    $Findings = Join-Path $Root 'findings.json'
    @{
        upstreamSha = $Base; nightlyTag = $Inputs.NightlyTag
        customizations = @(@{
            branch = 'customizations/fixture'; sha = $Base; coverage = 'full'
            description = 'Fixture behavior.'; finding = 'Present upstream.'; decision = 'skip'; disposition = 'skipped'
            evidence = @(@{ label = 'current upstream code'; url = "https://github.com/pingdotgg/t3code/blob/$Base/feature.txt" })
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Findings
    $Record = Save-OverlapFindings @Inputs -FindingsFile $Findings
    if ($Record -ne (Join-Path (Get-BuildCacheDirectory $Repo) 'overlap/findings.json')) { throw 'Ledger is not under the main checkout cache' }
    $Inputs.Repo = $Linked
    $Warm = Get-OverlapReviewPlan @Inputs
    if ($Warm.scope -ne 'unchanged' -or $Warm.customizations[0].scope -ne 'unchanged' -or !$Warm.requiresVerification) { throw 'Linked checkout missed unchanged shared evidence' }
    $Previous = $Warm.customizations[0].previous
    if ($Previous.ContainsKey('decision') -or $Previous.ContainsKey('disposition') -or $Previous.description -ne 'Fixture behavior.') { throw 'Cache lost descriptions or reused a human approval' }

    Set-Content (Join-Path $Repo 'feature.txt') 'new upstream implementation'
    git -C $Repo commit -am 'implement feature' | Out-Null
    $Next = (git -C $Repo rev-parse HEAD).Trim()
    $Inputs.UpstreamSha = $Next
    $Delta = Get-OverlapReviewPlan @Inputs
    if ($Delta.scope -ne 'delta' -or $Delta.upstreamCommits.Count -ne 1 -or $Delta.upstreamChangedFiles -notcontains 'feature.txt') { throw 'New upstream implementation was not surfaced' }
    $Inputs.PublishedSha = $Next; $Inputs.NightlyTag = 'v0.1.1-nightly.2'
    $Released = Get-OverlapReviewPlan @Inputs
    if ($Released.publishedChangedFiles -notcontains 'feature.txt') { throw 'Newly published code was not surfaced' }
    git -C $Repo update-ref refs/remotes/origin/customizations/fixture $Next
    if ((Get-OverlapReviewPlan @Inputs).customizations[0].scope -ne 'full') { throw 'Changed customization reused its old classification' }
    git -C $Repo update-ref refs/remotes/origin/customizations/new $Next
    $New = @((Get-OverlapReviewPlan @Inputs).customizations | Where-Object branch -eq 'customizations/new')[0]
    if ($New.scope -ne 'full' -or $New.previous) { throw 'New customization did not require full research' }
    git -C $Repo update-ref -d refs/remotes/origin/customizations/new

    $Saved = Get-Content -LiteralPath $Record -Raw | ConvertFrom-Json -AsHashtable
    $Saved.policyHash = 'outdated policy'
    $Saved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Record
    if ((Get-OverlapReviewPlan @Inputs).scope -ne 'full') { throw 'Changed verification policy reused a delta' }
    $Saved.policyHash = Get-OverlapPolicyHash
    $Saved.upstreamSha = '1' * 40
    $Saved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Record
    if ((Get-OverlapReviewPlan @Inputs).scope -ne 'full') { throw 'Missing history reused a delta' }
    Set-Content -LiteralPath $Record '{'
    if ((Get-OverlapReviewPlan @Inputs).scope -ne 'full') { throw 'Corrupt cache did not fall back to full research' }

    $Helper = Join-Path $PSScriptRoot '../scripts/overlap.ps1'
    & $Helper -Repo $Linked -UpstreamRef $Next -NightlyTag $Inputs.NightlyTag -PublishedRef $Next
    $Plans = @(Get-ChildItem (Join-Path (Get-BuildCacheDirectory $Repo) 'overlap/reviews') -Filter '*.json')
    if ($Plans.Count -ne 1) { throw 'CLI review plan was not written to the shared cache' }
    if (git -C $Repo status --porcelain) { throw 'Overlap cache dirtied the main checkout' }
    Write-Host 'PASS: cold/warm/shared overlap ledger; delta commits/files/releases; customization/policy/history invalidation; corrupt fallback; no cached approvals'
} finally { Remove-Item -LiteralPath $Root -Recurse -Force }
