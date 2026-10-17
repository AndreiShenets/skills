param(
    [Parameter(Mandatory)][ValidateSet('Sync', 'Merge', 'Build', 'Publish')][string]$Stage,
    [string]$Repo,
    [string]$Run,
    [string]$NotesFile,
    [string]$WslDistro,
    [ValidatePattern('^customizations/.+')][string[]]$SkipBranches = @()
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'git.ps1')
. (Join-Path $PSScriptRoot 'progress.ps1')
if ($PSBoundParameters.ContainsKey('SkipBranches') -and ($Stage -ne 'Sync' -or $Run)) {
    throw 'Choose SkipBranches when starting Sync; existing runs keep their saved selection'
}

function Save-Run {
    $Temporary = "$Run.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Temporary -Encoding utf8NoBOM
    [IO.File]::Move($Temporary, $Run, $true)
}

if (!$Run) {
    if ($Stage -ne 'Sync' -or !$Repo) { throw 'Start with Sync -Repo <checkout>; then pass its printed -Run path' }
    $Repo = (git -C $Repo rev-parse --show-toplevel).Trim()
    Assert-Clean $Repo
    if ((git -C $Repo remote get-url origin) -notmatch '[:/]AndreiShenets/t3code(?:\.git)?$') { throw 'Wrong origin' }
    $Now = Get-Date
    $RunId = $Now.ToString('yyyy_MM_dd_HH_mm')
    $Cache = Get-BuildCacheDirectory -Worktree $Repo
    $Scratch = Join-Path (Split-Path $Cache) ("runs/$RunId-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $Scratch | Out-Null
    $Run = Join-Path $Scratch 'run.json'
    $State = [ordered]@{
        Repo = $Repo; Scratch = $Scratch; RunId = $RunId; Stamp = $Now.ToString('yyyyMMddHHmm')
        Timestamp = $Now.ToString('o'); NightlyTag = ''; Version = ''; UpstreamSha = ''; MainSha = ''
        Branches = @(); SkippedBranches = @($SkipBranches | Sort-Object -Unique)
        Customizations = [ordered]@{}; Integrated = [ordered]@{}; BuildBranch = "custom_builds/$RunId"
        Work = (Join-Path $Scratch 'build'); Out = (Join-Path $Repo "release/as-custom/$RunId")
        BuildSha = ''; Merged = $false; Built = $false; WslSmoke = $false; ReleaseUrl = ''; Cache = $Cache
    }
    Save-Run
} else {
    $Run = (Resolve-Path -LiteralPath $Run).Path
}
Write-Host "Run: $Run"
try { $RunLock = [IO.File]::Open("$Run.lock", 'OpenOrCreate', 'ReadWrite', 'None') }
catch { throw "Run is already active or cannot be locked: $Run" }
try {
    $State = Get-Content -LiteralPath $Run -Raw | ConvertFrom-Json -AsHashtable
    if (!$State.Contains('Integrated')) { $State.Integrated = [ordered]@{} }
    if (!$State.Contains('SkippedBranches')) { $State.SkippedBranches = @() }
    if (!$State.Cache) { $State.Cache = Get-BuildCacheDirectory -Worktree $(if ($State.Repo) { $State.Repo } else { $State.Work }) }

    Invoke-BuildStep -Label $Stage -Action { switch ($Stage) {
    Sync {
        Complete-PendingMerge -Scratch $State.Scratch
        if ($State.MainSha) { Write-Host 'Sync already complete'; break }
        gh auth status
        $RemoteBranches = @(Get-RemoteCustomizationBranches -Repo $State.Repo)
        if (!$RemoteBranches.Count) { throw 'No remote customizations/* branches found' }
        foreach ($Branch in $State.SkippedBranches) {
            if ($Branch -cnotin $RemoteBranches) { throw "Skipped branch does not exist on origin: $Branch" }
        }
        $State.Branches = @($RemoteBranches | Where-Object { $_ -cnotin $State.SkippedBranches })
        if (!$State.Branches.Count) { throw 'All remote customizations are skipped; no custom build to create' }
        if (!$State.UpstreamSha) {
            $Nightly = gh release list --repo pingdotgg/t3code --limit 100 --json tagName,publishedAt,isPrerelease |
                ConvertFrom-Json | Where-Object { $_.isPrerelease -and $_.tagName -match '^v\d+\.\d+\.\d+-nightly\.' } |
                Sort-Object publishedAt -Descending | Select-Object -First 1
            if (!$Nightly) { throw 'No upstream nightly found' }
            $State.NightlyTag = $Nightly.tagName
            $State.Version = [regex]::Match($Nightly.tagName, '^v(\d+\.\d+\.\d+)-nightly\.').Groups[1].Value
            git -C $State.Repo fetch https://github.com/pingdotgg/t3code.git main
            $State.UpstreamSha = (git -C $State.Repo rev-parse FETCH_HEAD).Trim()
            Save-Run
        }
        Merge-TrackedBranch -Repo $State.Repo -Branch main -MergeRef $State.UpstreamSha -Scratch $State.Scratch
        $State.MainSha = (git -C $State.Repo rev-parse main).Trim()
        Save-Run
    }
    Merge {
        if (!$State.MainSha) { throw 'Complete Sync first' }
        if ($State.Merged) { Write-Host 'Merge already complete'; break }
        Complete-PendingMerge -Scratch $State.Scratch
        $RemoteBranches = @(Get-RemoteCustomizationBranches -Repo $State.Repo | Where-Object { $_ -cnotin $State.SkippedBranches })
        if (!$RemoteBranches.Count) { throw 'No selected remote customizations/* branches found' }
        if ($State.Customizations.Count -and @(Compare-Object @($State.Branches) $RemoteBranches).Count) {
            throw 'Remote customization inventory changed during merging; start a new run'
        }
        $State.Branches = $RemoteBranches
        Save-Run
        $Index = 0
        foreach ($Branch in $State.Branches) {
            $Index++
            if ($State.Customizations.Contains($Branch)) {
                Write-Host "[Merge $Index/$($State.Branches.Count)] Already updated: $Branch"
                git -C $State.Repo merge-base --is-ancestor $State.MainSha $State.Customizations[$Branch]
            } else {
                Write-Host "[Merge $Index/$($State.Branches.Count)] Update and push: $Branch"
                Merge-TrackedBranch -Repo $State.Repo -Branch $Branch -MergeRef $State.MainSha -Scratch $State.Scratch
                $State.Customizations[$Branch] = (git -C $State.Repo rev-parse "refs/heads/$Branch").Trim()
                Save-Run
            }
        }
        if (!(Test-Path -LiteralPath $State.Work)) {
            git -C $State.Repo worktree add -b $State.BuildBranch $State.Work $State.MainSha
        }
        Assert-Clean $State.Work
        if ((git -C $State.Work symbolic-ref --short HEAD).Trim() -cne $State.BuildBranch) { throw 'Build branch changed' }
        $Index = 0
        foreach ($Branch in $State.Branches) {
            $Index++
            $Sha = $State.Customizations[$Branch]
            if ($State.Integrated.Contains($Branch)) {
                if ($State.Integrated[$Branch] -ne $Sha) { throw 'Integrated customization inputs changed' }
                git -C $State.Work merge-base --is-ancestor $Sha HEAD
                Write-Host "[Integrate $Index/$($State.Branches.Count)] Already merged: $Branch"
            } else {
                Write-Host "[Integrate $Index/$($State.Branches.Count)] $Branch"
                Merge-VerifiedRef -Path $State.Work -MergeRef $Sha -Scratch $State.Scratch -Label $Branch
                $State.Integrated[$Branch] = $Sha
                Save-Run
            }
        }
        foreach ($Sha in @($State.MainSha) + @($State.Customizations.Values)) {
            git -C $State.Work merge-base --is-ancestor $Sha HEAD
        }
        git -C $State.Work push --set-upstream origin $State.BuildBranch
        $State.Merged = $true
        Save-Run
    }
    Build {
        if (!$State.Merged) { throw 'Complete Merge first' }
        Assert-Clean $State.Work
        if ((git -C $State.Work symbolic-ref --short HEAD).Trim() -cne $State.BuildBranch) { throw 'Build branch changed' }
        $State.Built = $false
        $State.WslSmoke = $false
        Save-Run
        Push-Location $State.Work
        try {
            Invoke-BuildStep -Label 'Windows dependencies (shared store)' -Action {
                vp install --frozen-lockfile --store-dir (Join-Path $State.Cache 'pnpm-store')
            }
            node scripts/update-release-package-versions.ts $State.Version
            $Manifests = @('apps/server/package.json', 'apps/desktop/package.json', 'apps/web/package.json', 'packages/contracts/package.json')
            foreach ($File in $Manifests) {
                if ((Get-Content $File -Raw | ConvertFrom-Json).version -ne $State.Version) { throw "Wrong version: $File" }
            }
            git add -- @Manifests
            if (git diff --cached --name-only) { git commit -m "chore(release): stamp AS Custom $($State.Version) $($State.Stamp)" }
            git push origin $State.BuildBranch
            Assert-Clean $State.Work
            $State.BuildSha = (git rev-parse HEAD).Trim()
            Save-Run
            $PreviousAppVersion = [Environment]::GetEnvironmentVariable('APP_VERSION', 'Process')
            try {
                $env:APP_VERSION = $State.Version
                Invoke-BuildStep -Label 'Windows/server/client compilation' -Action {
                    vp run build:desktop
                    node scripts/apply-web-brand-assets.ts production apps/server/dist/client
                }
            } finally { [Environment]::SetEnvironmentVariable('APP_VERSION', $PreviousAppVersion, 'Process') }
        } finally { Pop-Location }
        & (Join-Path $PSScriptRoot 'build-with-wsl.ps1') -Worktree $State.Work -Scratch $State.Scratch -RunId $State.RunId -Version $State.Version -OutputDir $State.Out
        if ($WslDistro) {
            $Script = (wsl.exe -d $WslDistro -- wslpath -u (Join-Path $PSScriptRoot 'wsl-smoke.sh')).Trim()
            $Archive = (wsl.exe -d $WslDistro -- wslpath -u (Join-Path $State.Out "t3-$($State.Version)-linux-x64.tar.gz")).Trim()
            wsl.exe -d $WslDistro -- bash $Script $Archive $State.Version
            $State.WslSmoke = $true
        }
        Assert-Clean $State.Work
        if ((git -C $State.Work rev-parse HEAD).Trim() -ne $State.BuildSha) { throw 'Source changed during build' }
        $State.Built = $true
        Save-Run
    }
    Publish {
        if (!$State.Built) { throw 'Complete Build first' }
        if ($State.ReleaseUrl) { Write-Host $State.ReleaseUrl; break }
        if (!$NotesFile -or !(Test-Path -LiteralPath $NotesFile)) { throw 'Supply -NotesFile <release-notes.md>' }
        Assert-Clean $State.Work
        if ((git -C $State.Work rev-parse HEAD).Trim() -ne $State.BuildSha) { throw 'Source changed after build' }
        . (Join-Path $PSScriptRoot 'publish.ps1')
        $State.ReleaseUrl = Publish-CustomRelease -State $State -NotesFile $NotesFile
        Save-Run
        Write-Host $State.ReleaseUrl
    }
    } }
} finally { $RunLock.Dispose() }
