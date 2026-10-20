$ErrorActionPreference = 'Stop'
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-notes-test-" + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot '../scripts/release-notes.ps1')
try {
    New-Item -ItemType Directory -Path $Root | Out-Null
    $Sha = 'a' * 40
    $State = @{ Branches = @('customizations/demo'); SkippedBranches = @(); Customizations = @{ 'customizations/demo' = $Sha }; UpstreamSha = $Sha; MainSha = $Sha; BuildSha = $Sha; Version = '0.1.1'; BuildBranch = 'custom_builds/2026_10_20_07_58'; Timestamp = '2026-10-20T07:58:47.7905462+05:30'; NightlyTag = 'v0.1.1-nightly.20261020.3386' }
    $Row = @{ branch = 'customizations/demo'; sha = $Sha; description = 'Describes the concrete custom behavior.'; coverage = 'absent'; finding = 'Upstream lacks this behavior.'; disposition = 'retained'; evidence = @(
        @{ label = 'published nightly code'; url = "https://github.com/pingdotgg/t3code/blob/$($State.NightlyTag)/package.json" },
        @{ label = 'current upstream code'; url = "https://github.com/pingdotgg/t3code/blob/$Sha/package.json" }
    ) }
    $Findings = @{ upstreamSha = $Sha; nightlyTag = $State.NightlyTag; customizations = @($Row) }
    $File = Join-Path $Root 'findings.json'
    function Render { $Findings | ConvertTo-Json -Depth 8 | Set-Content $File; Get-CustomReleaseNotes -State $State -FindingsFile $File }
    function Reject {
        $Failed = $false
        try { Render | Out-Null } catch { $Failed = $true }
        if (!$Failed) { throw 'Invalid release notes were accepted' }
    }
    $Notes = Render
    if (!$Notes.Contains('`2026-10-20T07:58:47.7905462+05:30`') -or
        !$Notes.Contains('| `customizations/demo` | [aaaaaaaaaaaa]') -or
        @($Notes -split "`n" | Where-Object { $_ -match '^## ' }).Count -ne 3 -or !$Notes.Contains('All included.')) { throw 'Release template/frozen values were not preserved' }
    $Row.coverage = 'full'; Reject
    $Row.decision = 'keep'; Render | Out-Null
    $Row.sha = 'b' * 40; Reject; $Row.sha = $Sha
    $Row.description = '[link](https://example.invalid)'; Reject; $Row.description = 'Concrete behavior.'
    $Findings.customizations = @(); Reject
    $Findings.customizations = @($Row, $Row); Reject
    $Findings.customizations = @($Row)
    $Findings.upstreamSha = 'b' * 40; Reject; $Findings.upstreamSha = $Sha
    $Row.evidence[1].url = 'https://github.com/pingdotgg/t3code/blob/main/package.json'; Reject
    $Row.evidence[1].url = "https://github.com/pingdotgg/t3code/blob/$Sha/package.json"
    $State.Branches = @(); $State.SkippedBranches = @('customizations/demo'); $Row.disposition = 'skipped'; $Row.decision = 'skip'
    $Notes = Render
    if (!$Notes.Contains('- Skipped branches: `customizations/demo`.') -or !$Notes.Contains('Skipped: `customizations/demo`. Removed: none. All others included.')) { throw 'Approved skips were not rendered' }
    $State.SkippedBranches = @(); $Row.disposition = 'removed'; $Row.decision = 'remove'
    if (!(Render).Contains('Removed: `customizations/demo`. All others included.')) { throw 'Approved removal lost its frozen input' }
    $Row.decision = ''; Reject
    Write-Host 'PASS: deterministic note template; exact timestamp offset; frozen SHAs; inventory/coverage/evidence checks; explicit full/skip/remove decisions'
} finally { Remove-Item -LiteralPath $Root -Recurse -Force }
