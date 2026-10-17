param(
    [Parameter(Mandatory)][ValidateSet('Sync', 'Merge', 'Build', 'Publish')][string]$Stage,
    [string]$Repo,
    [string]$Run,
    [string]$NotesFile,
    [string]$WslDistro
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'git.ps1')

function Save-Run {
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Run -Encoding utf8NoBOM
}

if (!$Run) {
    if ($Stage -ne 'Sync' -or !$Repo) { throw 'Start with Sync -Repo <checkout>; then pass its printed -Run path' }
    $Repo = (git -C $Repo rev-parse --show-toplevel).Trim()
    Assert-Clean $Repo
    if ((git -C $Repo remote get-url origin) -notmatch '[:/]AndreiShenets/t3code(?:\.git)?$') { throw 'Wrong origin' }
    $Now = Get-Date
    $RunId = $Now.ToString('yyyy_MM_dd_HH_mm')
    $Scratch = Join-Path ([IO.Path]::GetTempPath()) ("t3-custom-$RunId-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $Scratch | Out-Null
    $Run = Join-Path $Scratch 'run.json'
    $State = [ordered]@{
        Repo = $Repo; Scratch = $Scratch; RunId = $RunId; Stamp = $Now.ToString('yyyyMMddHHmm')
        Timestamp = $Now.ToString('o'); NightlyTag = ''; Version = ''; UpstreamSha = ''; MainSha = ''
        Branches = @(); Customizations = [ordered]@{}; BuildBranch = "custom_builds/$RunId"
        Work = (Join-Path $Scratch 'build'); Out = (Join-Path $Repo "release/as-custom/$RunId")
        BuildSha = ''; Merged = $false; Built = $false; WslSmoke = $false; ReleaseUrl = ''
    }
    Save-Run
} else {
    $Run = (Resolve-Path -LiteralPath $Run).Path
    $State = Get-Content -LiteralPath $Run -Raw | ConvertFrom-Json -AsHashtable
}
Write-Host "Run: $Run"

switch ($Stage) {
    Sync {
        if ($State.MainSha) { Write-Host 'Sync already complete'; break }
        gh auth status
        $State.Branches = @(Get-RemoteCustomizationBranches -Repo $State.Repo)
        if (!$State.Branches.Count) { throw 'No remote customizations/* branches found' }
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
        $RemoteBranches = @(Get-RemoteCustomizationBranches -Repo $State.Repo)
        if (!$RemoteBranches.Count) { throw 'No remote customizations/* branches found' }
        if ($State.Customizations.Count -and @(Compare-Object @($State.Customizations.Keys) $RemoteBranches).Count) {
            throw 'Remote customization inventory changed during merging; start a new run'
        }
        $State.Branches = $RemoteBranches
        Save-Run
        if (!$State.Customizations.Count) {
            foreach ($Branch in $State.Branches) {
                Merge-TrackedBranch -Repo $State.Repo -Branch $Branch -MergeRef $State.MainSha -Scratch $State.Scratch
            }
            foreach ($Branch in $State.Branches) {
                $State.Customizations[$Branch] = (git -C $State.Repo rev-parse "refs/heads/$Branch").Trim()
            }
            Save-Run
        }
        if (!(Test-Path -LiteralPath $State.Work)) {
            git -C $State.Repo worktree add -b $State.BuildBranch $State.Work $State.MainSha
        }
        Assert-Clean $State.Work
        if ((git -C $State.Work symbolic-ref --short HEAD).Trim() -cne $State.BuildBranch) { throw 'Build branch changed' }
        foreach ($Entry in $State.Customizations.GetEnumerator()) { git -C $State.Work merge --no-edit $Entry.Value }
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
            vp install --frozen-lockfile
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
                vp run build:desktop
                node scripts/apply-web-brand-assets.ts production apps/server/dist/client
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
}
