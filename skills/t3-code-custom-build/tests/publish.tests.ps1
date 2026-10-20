$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Root = Join-Path ([IO.Path]::GetTempPath()) ("t3-skill-publish-test-" + [guid]::NewGuid().ToString('N'))
$Work = Join-Path $Root 'work'
$Out = Join-Path $Root 'out'
$Scratch = Join-Path $Root 'scratch'
New-Item -ItemType Directory -Path $Work, $Out, $Scratch | Out-Null
$Mock = @{
    Release = $null; Bytes = @{}; Creates = 0; Uploads = 0; Edits = 0; Downloads = 0
    FailDraft = $true; FailUpload = $true; FailDownload = $true; FailEdit = $true
    FailCleanup = $true; CleanupAttempts = 0
}

function docker {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'ps') {
        $Mock.CleanupAttempts++
        if ($Mock.FailCleanup) { $Mock.FailCleanup = $false; throw 'simulated cleanup unavailable' }
    } elseif ($args[0] -ne 'volume' -or $args[1] -ne 'ls') { throw 'Unexpected cleanup command' }
}

function gh {
    $Command = $args[1]
    $Tag = $args[2]
    $global:LASTEXITCODE = 0
    switch ($Command) {
        view {
            if (!$Mock.Release) { $global:LASTEXITCODE = 1; 'release not found'; return }
            $Mock.Release.assets = @($Mock.Bytes.GetEnumerator() | ForEach-Object {
                @{ name = $_.Key; size = $_.Value.Length; state = 'uploaded' }
            })
            $Mock.Release | ConvertTo-Json -Depth 5 -Compress
        }
        create {
            if ($Mock.Release) { throw 'Duplicate release creation' }
            $TitleIndex = [array]::IndexOf($args, '--title')
            $NotesIndex = [array]::IndexOf($args, '--notes-file')
            $Mock.Release = @{
                tagName = $Tag; name = $args[$TitleIndex + 1]; url = 'https://example.invalid/custom-release'
                isDraft = $true; isPrerelease = $true; assets = @()
                body = Get-Content -LiteralPath $args[$NotesIndex + 1] -Raw
            }
            $Mock.Creates++
            if ($Mock.FailDraft) { $Mock.FailDraft = $false; throw 'interrupted after draft creation' }
        }
        upload {
            if ($args -contains '--clobber') { throw 'Remote asset overwrite requested' }
            $File = $args[3]
            $Name = Split-Path -Leaf $File
            if ($Mock.Bytes.ContainsKey($Name)) { throw 'Existing asset reuploaded' }
            $Mock.Bytes[$Name] = [IO.File]::ReadAllBytes($File)
            $Mock.Uploads++
            if ($Mock.FailUpload) { $Mock.FailUpload = $false; throw 'interrupted after installer upload' }
        }
        download {
            if ($args -notcontains '--clobber') { throw 'Partial verification files cannot be replaced' }
            $DirIndex = [array]::IndexOf($args, '--dir')
            $Directory = $args[$DirIndex + 1]
            New-Item -ItemType Directory -Force -Path $Directory | Out-Null
            foreach ($Entry in $Mock.Bytes.GetEnumerator()) {
                [IO.File]::WriteAllBytes((Join-Path $Directory $Entry.Key), $Entry.Value)
                if ($Mock.FailDownload) { $Mock.FailDownload = $false; throw 'interrupted during download' }
            }
            $Mock.Downloads++
        }
        edit {
            if (!$Mock.Release.isDraft) { throw 'Published release edited on resume' }
            if ($args -notcontains '--latest=false') { throw 'Release could be marked latest' }
            $Mock.Release.isDraft = $false
            $Mock.Edits++
            if ($Mock.FailEdit) { $Mock.FailEdit = $false; throw 'interrupted after publication' }
        }
        default { throw "Unexpected GitHub command: $Command" }
    }
}

try {
    git init --initial-branch=main $Work | Out-Null
    git init --bare --initial-branch=main (Join-Path $Root 'origin.git') | Out-Null
    git -C $Work config user.name 'Skill Test'
    git -C $Work config user.email 'skill-test@example.invalid'
    git -C $Work config commit.gpgsign false
    git -C $Work config tag.gpgsign false
    git -C $Work config core.hooksPath (Join-Path $Root 'empty-hooks')
    Set-Content (Join-Path $Work 'source.txt') 'fixture'
    git -C $Work add .
    git -C $Work commit -m fixture | Out-Null
    git -C $Work remote add origin (Join-Path $Root 'origin.git')
    git -C $Work push -u origin main | Out-Null
    $Sha = (git -C $Work rev-parse HEAD).Trim()
    Set-Content (Join-Path $Out 'T3-Code-0.1.1-x64.exe') 'fake installer'
    $Archive = Join-Path $Out 't3-0.1.1-linux-x64.tar.gz'
    Set-Content $Archive 'fake verified archive'
    $Notes = Join-Path $Root 'notes.md'
    Set-Content $Notes 'fixture notes'
    $Run = Join-Path $Scratch 'run.json'
    $State = @{
        Built = $true; Work = $Work; Out = $Out; Scratch = $Scratch; BuildSha = $Sha; MainSha = $Sha; PreflightSha = ''
        Version = '0.1.1'; Stamp = '202610171539'; ReleaseUrl = ''
        RunId = '2026_10_17_15_39'; BuildBranch = 'custom_builds/2026_10_17_15_39'
        Timestamp = '2026-10-17T15:39:00.0000000+05:30'; UpstreamSha = $Sha
        NightlyTag = 'v0.1.1-nightly.20261017.1'; Branches = @('customizations/demo'); SkippedBranches = @()
        Customizations = @{ 'customizations/demo' = $Sha }; BuildKey = "$Sha-fixture"
    }
    $State | ConvertTo-Json | Set-Content $Run
    $Workflow = Join-Path $PSScriptRoot '../scripts/workflow.ps1'
    $PreflightBlocked = $false
    try { & $Workflow -Stage Publish -Run $Run -NotesFile $Notes } catch {
        if ($_.Exception.Message -ne 'Complete Build with passing preflight for this source first') { throw }
        $PreflightBlocked = $true
    }
    if (!$PreflightBlocked -or $Mock.Creates) { throw 'Unverified source reached publication' }
    $State.PreflightSha = $Sha
    $State | ConvertTo-Json | Set-Content $Run
    $Blocked = $false
    try { & $Workflow -Stage Publish -Run $Run -NotesFile $Notes } catch {
        if ($_.Exception.Message -ne 'Complete Build with verified artifact checkpoints before publication') { throw }
        $Blocked = $true
    }
    if (!$Blocked -or $Mock.Creates) { throw 'Legacy Built flag bypassed artifact verification' }
    . (Join-Path $PSScriptRoot '../scripts/checkpoints.ps1')
    Save-BuildCheckpoint -Scratch $Scratch -Name installer -Key $State.BuildKey -Files @($Archive, (Join-Path $Out 'T3-Code-0.1.1-x64.exe'))
    $Findings = Join-Path $Root 'findings.json'
    @{ upstreamSha = $Sha; nightlyTag = $State.NightlyTag; customizations = @(@{
        branch = 'customizations/demo'; sha = $Sha; description = 'Concrete custom behavior.'; coverage = 'absent'
        disposition = 'retained'; finding = 'Upstream lacks this behavior.'; evidence = @(
            @{ label = 'published nightly code'; url = "https://github.com/pingdotgg/t3code/blob/$($State.NightlyTag)/package.json" },
            @{ label = 'current upstream code'; url = "https://github.com/pingdotgg/t3code/blob/$Sha/package.json" }
        )
    }) } | ConvertTo-Json -Depth 8 | Set-Content $Findings
    & $Workflow -Stage Notes -Run $Run -FindingsFile $Findings -NotesFile $Notes
    if (!(Get-Content $Notes -Raw).Contains($State.Timestamp)) { throw 'Notes stage changed original timestamp offset' }
    $GoodNotes = Get-Content $Notes -Raw
    Set-Content $Notes 'tampered notes'
    $Blocked = $false
    try { & $Workflow -Stage Publish -Run $Run -NotesFile $Notes } catch {
        if ($_.Exception.Message -notlike 'Release notes disagree*') { throw }
        $Blocked = $true
    }
    if (!$Blocked -or $Mock.Creates) { throw 'Invalid notes reached publication' }
    Set-Content $Notes $GoodNotes
    foreach ($Expected in @('interrupted after draft creation', 'interrupted after installer upload', 'interrupted during download', 'interrupted after publication')) {
        $Failed = $false
        try { & $Workflow -Stage Publish -Run $Run -NotesFile $Notes } catch {
            if ($_.Exception.Message -ne $Expected) { throw }
            $Failed = $true
        }
        if (!$Failed) { throw "Interruption was not exercised: $Expected" }
    }
    & $Workflow -Stage Publish -Run $Run -NotesFile $Notes
    if (!(Get-Content $Run -Raw | ConvertFrom-Json).CleanupPending) { throw 'Cleanup failure was not recorded after publication' }
    & $Workflow -Stage Publish -Run $Run
    if ((Get-Content $Run -Raw | ConvertFrom-Json).CleanupPending -or $Mock.CleanupAttempts -ne 2) { throw 'Completed publication did not retry cleanup' }
    if ($Mock.Creates -ne 1 -or $Mock.Uploads -ne 2 -or $Mock.Edits -ne 1) { throw 'Resume duplicated a release mutation' }
    if ((Get-Content $Run -Raw | ConvertFrom-Json).ReleaseUrl -ne $Mock.Release.url) { throw 'Published state was not recovered' }

    $State = Get-Content $Run -Raw | ConvertFrom-Json -AsHashtable
    $State.Timestamp = '2026-10-17T15:39:00.0000000+05:30'
    $State.ReleaseUrl = ''
    $State | ConvertTo-Json | Set-Content $Run
    $InstallerName = 'T3-Code-AS-Custom-0.1.1-202610171539-x64.exe'
    $Mock.Bytes[$InstallerName][0] = $Mock.Bytes[$InstallerName][0] -bxor 1
    $MismatchBlocked = $false
    try { & $Workflow -Stage Publish -Run $Run -NotesFile $Notes } catch {
        if ($_.Exception.Message -ne 'Uploaded installer checksum mismatch') { throw }
        $MismatchBlocked = $true
    }
    if (!$MismatchBlocked -or $Mock.Uploads -ne 2 -or $Mock.Edits -ne 1) { throw 'Published asset mismatch was not blocked safely' }
    Write-Host 'PASS: draft/upload/download/publication interruption recovery; idempotent completion; mismatched published bytes blocked'
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
