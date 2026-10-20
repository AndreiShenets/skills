function Get-CustomReleaseNotes {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$FindingsFile)
    $Findings = Get-Content -LiteralPath $FindingsFile -Raw | ConvertFrom-Json
    if ($Findings.upstreamSha -cne $State.UpstreamSha -or $Findings.nightlyTag -cne $State.NightlyTag) {
        throw 'Overlap findings do not match the frozen upstream inputs'
    }
    $Rows = @($Findings.customizations | Sort-Object branch)
    $Names = @($Rows | ForEach-Object { $_.branch })
    if (!$Rows.Count -or @($Names | Sort-Object -Unique).Count -ne $Names.Count) { throw 'Duplicate or empty customization findings' }
    foreach ($Branch in @($State.Branches) + @($State.SkippedBranches)) {
        if ($Branch -cnotin $Names) { throw "Missing customization findings: $Branch" }
    }
    foreach ($Row in $Rows) {
        if ($Row.branch -notmatch '^customizations/[\w./-]+$' -or $Row.sha -notmatch '^[a-f0-9]{40}$') { throw 'Invalid customization identity' }
        if ($Row.coverage -cnotin @('full', 'partial', 'absent', 'unreleased', 'unverified')) { throw "Invalid coverage: $($Row.branch)" }
        $Expected = if ($Row.branch -cin $State.Branches) { 'retained' }
            elseif ($Row.branch -cin $State.SkippedBranches) { 'skipped' } else { 'removed' }
        if ($Row.disposition -cne $Expected) { throw "Disposition disagrees with run: $($Row.branch)" }
        if ($Expected -eq 'retained' -and $Row.sha -cne $State.Customizations[$Row.branch]) { throw "Customization SHA disagrees with run: $($Row.branch)" }
        $Decision = @{ retained = 'keep'; skipped = 'skip'; removed = 'remove' }[$Expected]
        if (($Row.coverage -eq 'full' -or $Expected -ne 'retained') -and $Row.decision -cne $Decision) {
            throw "Explicit $Decision decision required: $($Row.branch)"
        }
        foreach ($Text in @($Row.description, $Row.finding)) {
            if ([string]::IsNullOrWhiteSpace($Text) -or $Text -match '[\r\n|]|<[^>]+>|\[[^]]*\]\(|https?://') { throw "Use plain-text paragraphs: $($Row.branch)" }
        }
        $Labels = @($Row.evidence | ForEach-Object { $_.label })
        if ('current upstream code' -cnotin $Labels -or
            !(@('published nightly code', 'published release') | Where-Object { $_ -cin $Labels })) {
            throw "Published and current code evidence required: $($Row.branch)"
        }
        foreach ($Link in $Row.evidence) {
            if ($Link.url -notmatch '^https://github\.com/(?:pingdotgg|AndreiShenets)/t3code/(?:blob|pull|releases/tag)/[^\s<>\[\]()]+$' -or
                $Link.label -notmatch '^(?:merged PR #\d+|published release|published nightly code|current upstream code|custom code)$') { throw 'Invalid evidence link' }
            if ($Link.label -eq 'current upstream code' -and !$Link.url.StartsWith("https://github.com/pingdotgg/t3code/blob/$($State.UpstreamSha)/")) { throw 'Current code evidence must use frozen upstream SHA' }
            if ($Link.label -eq 'published nightly code' -and !$Link.url.StartsWith("https://github.com/pingdotgg/t3code/blob/$($State.NightlyTag)/")) { throw 'Nightly code evidence must use frozen release tag' }
        }
    }
    foreach ($Value in @($State.MainSha, $State.BuildSha, $State.UpstreamSha)) {
        if ($Value -notmatch '^[a-f0-9]{40}$') { throw 'Release notes require frozen commit SHAs' }
    }
    if ($State.Timestamp -notmatch '^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$' -or
        $State.NightlyTag -notmatch '^v\d+\.\d+\.\d+-nightly\.[\w.]+$' -or
        $State.Version -notmatch '^\d+\.\d+\.\d+$' -or $State.BuildBranch -notmatch '^custom_builds/[\w_]+$') { throw 'Invalid frozen release-note source values' }
    $Lines = [Collections.Generic.List[string]]::new()
    $Lines.Add('## Source')
    $Lines.Add('')
    $Lines.Add("- Upstream nightly: [$($State.NightlyTag)](https://github.com/pingdotgg/t3code/releases/tag/$($State.NightlyTag)); base version **$($State.Version)**.")
    $Lines.Add('- Frozen timestamp: `' + $State.Timestamp + '`.')
    $Lines.Add("- Main: [$($State.MainSha)](https://github.com/AndreiShenets/t3code/commit/$($State.MainSha)).")
    $Lines.Add('- Build: `' + $State.BuildBranch + '` at [' + $State.BuildSha + '](https://github.com/AndreiShenets/t3code/commit/' + $State.BuildSha + ').')
    $Skipped = @($State.SkippedBranches | Sort-Object | ForEach-Object { '`' + $_ + '`' }) -join ', '
    $Lines.Add('- Skipped branches: ' + $(if ($Skipped) { $Skipped } else { 'none' }) + '.')
    $Lines.Add('')
    $Lines.Add('## Customization inputs')
    $Lines.Add('')
    $Lines.Add('| Branch | SHA |')
    $Lines.Add('| --- | --- |')
    foreach ($Row in $Rows) {
        $Lines.Add('| `' + $Row.branch + '` | [' + $Row.sha.Substring(0, 12) + '](https://github.com/AndreiShenets/t3code/commit/' + $Row.sha + ') |')
    }
    foreach ($Row in $Rows) {
        $Lines.Add('')
        $Lines.Add('### ' + $Row.branch.Substring('customizations/'.Length))
        $Lines.Add('')
        $Lines.Add($Row.description)
    }
    $Lines.Add('')
    $Removed = @($Rows | Where-Object disposition -eq removed | ForEach-Object { '`' + $_.branch + '`' }) -join ', '
    if (!$Skipped -and !$Removed) { $Lines.Add('All included.') }
    else { $Lines.Add('Skipped: ' + $(if ($Skipped) { $Skipped } else { 'none' }) + '. Removed: ' + $(if ($Removed) { $Removed } else { 'none' }) + '. All others included.') }
    $Lines.Add('')
    $Lines.Add('## Upstream overlap')
    $Lines.Add('')
    foreach ($Row in $Rows) {
        $Links = @($Row.evidence | ForEach-Object { "[$($_.label)]($($_.url))" }) -join '; '
        $Disposition = @{ retained = 'Retained'; skipped = 'Skipped'; removed = 'Removed' }[$Row.disposition]
        $Lines.Add("- **$($Row.branch.Substring('customizations/'.Length)) — $($Row.coverage).** $($Row.finding) $Disposition. $Links.")
    }
    ($Lines -join "`n") + "`n"
}
