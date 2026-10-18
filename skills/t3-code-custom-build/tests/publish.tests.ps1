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
            $Mock.Release = @{
                tagName = $Tag; name = $args[$TitleIndex + 1]; url = 'https://example.invalid/custom-release'
                isDraft = $true; isPrerelease = $true; assets = @()
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
    $Notes = Join-Path $Root 'notes.md'
    Set-Content $Notes 'fixture notes'
    $Run = Join-Path $Scratch 'run.json'
    $State = @{
        Built = $true; Work = $Work; Out = $Out; Scratch = $Scratch; BuildSha = $Sha; MainSha = $Sha; PreflightSha = ''
        Version = '0.1.1'; Stamp = '202610171539'; ReleaseUrl = ''
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
    foreach ($Expected in @('interrupted after draft creation', 'interrupted after installer upload', 'interrupted during download', 'interrupted after publication')) {
        $Failed = $false
        try { & $Workflow -Stage Publish -Run $Run -NotesFile $Notes } catch {
            if ($_.Exception.Message -ne $Expected) { throw }
            $Failed = $true
        }
        if (!$Failed) { throw "Interruption was not exercised: $Expected" }
    }
    & $Workflow -Stage Publish -Run $Run -NotesFile $Notes
    & $Workflow -Stage Publish -Run $Run -NotesFile $Notes
    if ($Mock.Creates -ne 1 -or $Mock.Uploads -ne 2 -or $Mock.Edits -ne 1) { throw 'Resume duplicated a release mutation' }
    if ((Get-Content $Run -Raw | ConvertFrom-Json).ReleaseUrl -ne $Mock.Release.url) { throw 'Published state was not recovered' }

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
