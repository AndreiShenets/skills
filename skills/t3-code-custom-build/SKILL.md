---
name: t3-code-custom-build
description: Sync T3 Code, merge customizations, build Windows x64 with WSL, and publish an AS Custom release.
disable-model-invocation: true
metadata:
  opencode/autoinvoke: false
---

# T3 Code AS Custom

PowerShell 7; Windows x64; Linux Docker daemon. Run in the target T3 Code checkout.

Resolve `$Skill` from the loader's base directory or the loaded `SKILL.md`'s parent. Agent-resolved; no fixed installation path.

Build command timeout: ≥900000 ms. After timeout, check the captured process/container before retrying.

## 1. Freeze inputs; sync fork/main

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Repo = (git rev-parse --show-toplevel).Trim()
$Skill = (Resolve-Path -LiteralPath $Skill).Path
if (!(Test-Path -LiteralPath (Join-Path $Skill 'SKILL.md'))) { throw 'Resolve the loaded skill directory first' }
$Now = Get-Date
$RunId = $Now.ToString('yyyy_MM_dd_HH_mm')
$Stamp = $Now.ToString('yyyyMMddHHmm')
$Scratch = Join-Path ([System.IO.Path]::GetTempPath()) "t3-custom-$RunId"
New-Item -ItemType Directory -Path $Scratch | Out-Null
. "$Skill\scripts\git.ps1"
Assert-Clean $Repo
if ((git -C $Repo remote get-url origin) -notmatch '[:/]AndreiShenets/t3code(?:\.git)?$') { throw 'Wrong origin' }
gh auth status
docker version --format '{{.Server.Os}}/{{.Server.Arch}}'
Get-Command git, gh, vp, node, cargo, rustc, python | Select-Object Name, Source

$Nightly = gh release list --repo pingdotgg/t3code --limit 100 --json tagName,publishedAt,isPrerelease |
  ConvertFrom-Json | Where-Object { $_.isPrerelease -and $_.tagName -match '^v\d+\.\d+\.\d+-nightly\.' } |
  Sort-Object publishedAt -Descending | Select-Object -First 1
if (!$Nightly) { throw 'No upstream nightly found; do not fall back to package.json or stable' }
$Version = [regex]::Match($Nightly.tagName, '^v(\d+\.\d+\.\d+)-nightly\.').Groups[1].Value

gh repo sync AndreiShenets/t3code --source pingdotgg/t3code --branch main
# If sync reports divergence, reconcile main with the user; never add --force.
git -C $Repo fetch origin --prune
Merge-TrackedBranch -Repo $Repo -Branch main -MergeRef origin/main -Scratch $Scratch -FastForwardOnly
$MainSha = (git -C $Repo rev-parse main).Trim()
$MainShort = $MainSha.Substring(0, 12)
$CustomizationBranches = @(git -C $Repo for-each-ref '--format=%(refname)' refs/heads/customizations/ refs/remotes/origin/customizations/ |
  ForEach-Object { $_ -replace '^refs/(heads/|remotes/origin/)', '' } | Sort-Object -Unique)
if (!$CustomizationBranches.Count) { throw 'No customizations/* branches found' }
```

## 2. Update every customization; create cumulative build branch

```powershell
foreach ($Branch in $CustomizationBranches) {
  Merge-TrackedBranch -Repo $Repo -Branch $Branch -MergeRef $MainSha -Scratch $Scratch
}
$CustomizationCommits = [ordered]@{}
foreach ($Branch in $CustomizationBranches) {
  $CustomizationCommits[$Branch] = (git -C $Repo rev-parse "refs/heads/$Branch").Trim()
}
$BuildBranch = "custom_builds/$RunId"
$Work = Join-Path $Scratch 'build'
git -C $Repo worktree add -b $BuildBranch $Work $MainSha
foreach ($Entry in $CustomizationCommits.GetEnumerator()) {
  git -C $Work merge --no-edit $Entry.Value
  git -C $Work merge-base --is-ancestor $Entry.Value HEAD
}
git -C $Work merge-base --is-ancestor $MainSha HEAD
git -C $Work push --set-upstream origin $BuildBranch
```

Conflicts: resolve, commit, validate affected code, then continue remaining branches. Helpers leave failed merges intact.

## 3. Stamp, commit, build

```powershell
Push-Location $Work
try {
  vp install --frozen-lockfile
  node scripts/update-release-package-versions.ts $Version
  $Manifests = @('apps/server/package.json', 'apps/desktop/package.json', 'apps/web/package.json', 'packages/contracts/package.json')
  foreach ($File in $Manifests) {
    if ((Get-Content $File -Raw | ConvertFrom-Json).version -ne $Version) { throw "Wrong version: $File" }
  }
  git add -- @Manifests
  if (git diff --cached --name-only) { git commit -m "chore(release): stamp AS Custom $Version $Stamp" }
  git push origin $BuildBranch
  Assert-Clean $Work
  $BuildSha = (git rev-parse HEAD).Trim()
  vp run build:desktop
  node scripts/apply-web-brand-assets.ts production apps/server/dist/client
} finally { Pop-Location }
$Out = Join-Path $Repo "release/as-custom/$RunId"
& "$Skill\scripts\build-with-wsl.ps1" -Worktree $Work -Scratch $Scratch -RunId $RunId -Version $Version -OutputDir $Out
```

Logs: `$Scratch/linux-build.log`, `$Scratch/windows-build.log`. Failed Linux container is retained; helper resumes it on retry.

Prerequisite failure: `docs/operations/development.md#windows-installer-prerequisites`. Host Node 26 worked. Helper derives Linux SEA Node from source. With VS 2026-only hosts, check the builder's VS 2022 override if native rebuilding fails.

## 4. Verify; publish only to the fork

Require helper success: Linux `--version` + isolated server HTTP smoke, Windows WSL archive/digest and native payload validation. If a WSL distro is available:

```powershell
wsl.exe --list --verbose
$Distro = 'Ubuntu-24.04' # Select an existing non-Docker distro from the list.
$WslScript = (wsl.exe -d $Distro -- wslpath -u "$Skill\scripts\wsl-smoke.sh").Trim()
$WslArchive = (wsl.exe -d $Distro -- wslpath -u (Join-Path $Out "t3-$Version-linux-x64.tar.gz")).Trim()
wsl.exe -d $Distro -- bash $WslScript $WslArchive $Version
```

```powershell
Assert-Clean $Work
if ((git -C $Work rev-parse HEAD).Trim() -ne $BuildSha) { throw 'Source changed after build' }
$AssetName = "T3-Code-AS-Custom-$Version-$Stamp-x64.exe"
$Installer = Join-Path $Out $AssetName
Copy-Item (Join-Path $Out "T3-Code-$Version-x64.exe") $Installer
$Checksums = Join-Path $Out 'SHA256SUMS'
$ExeSha = (Get-FileHash $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$ExeSha  $AssetName" | Set-Content $Checksums -Encoding utf8NoBOM
$LinuxName = "t3-$Version-linux-x64.tar.gz"
$LinuxSha = (Get-FileHash (Join-Path $Out $LinuxName) -Algorithm SHA256).Hash.ToLowerInvariant()
$Tag = "as-custom-v$Version-$Stamp"
$Title = "T3 Code AS Custom $Version $Stamp ($MainShort)"
$Notes = Join-Path $Scratch 'release-notes.md'
# Write notes: upstream nightly tag, local timestamp+UTC offset, full main/build/customization
# SHAs, Linux SHA256, validation results, unsigned status, actual installation/update behavior.
if (!(Test-Path $Notes)) { throw 'Write release-notes.md first' }
git -C $Work tag -a $Tag $BuildSha -m $Title
git -C $Work push origin "refs/tags/$Tag"
gh release create $Tag $Installer $Checksums --repo AndreiShenets/t3code --verify-tag --title $Title --notes-file $Notes --draft --prerelease --latest=false
$Release = gh release view $Tag --repo AndreiShenets/t3code --json url,isDraft,isPrerelease,assets | ConvertFrom-Json
if (!$Release.isDraft -or !$Release.isPrerelease) { throw 'Unexpected release state' }
$Asset = @($Release.assets | Where-Object { $_.name -ceq $AssetName })
if ($Asset.Count -ne 1 -or $Asset[0].size -ne (Get-Item $Installer).Length) { throw 'Installer asset mismatch' }
$Verify = Join-Path $Scratch 'download-verification'
gh release download $Tag --repo AndreiShenets/t3code --dir $Verify --pattern $AssetName --pattern SHA256SUMS
if ((Get-FileHash (Join-Path $Verify $AssetName) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExeSha) { throw 'Uploaded installer checksum mismatch' }
if ((Get-Content (Join-Path $Verify 'SHA256SUMS') -Raw).Trim() -cne "$ExeSha  $AssetName") { throw 'Uploaded checksum file mismatch' }
$RemoteTag = ((git -C $Work ls-remote origin "refs/tags/$Tag^{}") -split '\s+')[0]
if ($RemoteTag -ne $BuildSha) { throw 'Remote tag target mismatch' }
git -C $Work merge-base --is-ancestor $MainSha $BuildSha
gh release edit $Tag --repo AndreiShenets/t3code --draft=false --prerelease --latest=false
gh release view $Tag --repo AndreiShenets/t3code --json url,isDraft,isPrerelease,assets
git -C $Work status --short --branch
```

Retry: reuse existing branch/tag/release only for matching SHAs/assets. Custom tag prefix avoids upstream `v*` release triggers.

Report release URL, installer path/name, version, main/build SHAs, validation results, installation/update caveats.
