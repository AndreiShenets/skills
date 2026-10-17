---
name: t3-code-custom-build
description: Sync T3 Code, merge customizations, build Windows x64 with WSL, and publish an AS Custom release.
disable-model-invocation: true
metadata:
  opencode/autoinvoke: false
---

# T3 Code AS Custom

Explicit invocation authorizes the workflow below. PowerShell 7; Windows x64; Docker Linux containers. Read repository `AGENTS.md` first.

Agent initializes `$Skill` from the skill loader's absolute base directory; fallback: parent of the actual loaded `SKILL.md`. Discover it yourself, not via user configuration, a fixed global install path, `$PWD`, or `$PSScriptRoot` in pasted commands. Run in the target T3 Code checkout; `$Repo` and scratch paths are resolved below.

## Gates

- Preserve installation identity/updater from the merged code. Until a customization changes them: replacement installation, official updater, unsigned.
- Stop on any failed command. Resolve merge conflicts preserving both intents; commit, validate affected code, then resume. Ask on semantic ambiguity. Never force-push/reset or discard user changes.
- Borrow only clean existing branch worktrees. Separate build worktree; separate Linux dependencies. No live T3 home, installer execution, browser/UI testing, secrets, or `.env` copies.
- Use current build scripts; inspect upstream changes to them before executing. Node 26 worked; Windows need not be downgraded solely for the Node 24 engine warning. Linux SEA Node comes from `SEA_NODE_VERSION`, not an assumed version.
- Long builds: foreground timeout ≥900000 ms, or tracked background execution. After timeout inspect captured process/container before retrying; never duplicate an active build.

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

Bind the current harness session to `$Work` when supported. On conflicts, leave the affected worktree intact; finish that merge before continuing the loop. Verify every frozen customization SHA is an ancestor of the final build commit.

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
  vp test run scripts/update-release-package-versions.test.ts
  # Also run focused tests/lint/typechecks for conflict resolutions; no repo-wide checks.
  vp run build:desktop
  node scripts/apply-web-brand-assets.ts production apps/server/dist/client
} finally { Pop-Location }
$Out = Join-Path $Repo "release/as-custom/$RunId"
& "$Skill\scripts\build-with-wsl.ps1" -Worktree $Work -Scratch $Scratch -RunId $RunId -Version $Version -OutputDir $Out
```

Helper: native Linux x64 build from `git archive $BuildSha`, matching Windows client assets, Linux resource monitor, CLI archive smoke test, then Windows NSIS with `--wsl-runtime`. It preserves Docker resources on failure. Logs go to `$Scratch`; inspect/resume the exact container, not a duplicate.

If Windows prerequisite checks fail, inspect `docs/operations/development.md#windows-installer-prerequisites`. Require Rust/MSVC target, Python, SDK, C++ and Spectre libs. Ask before installing host tools. VS 2026 passes preflight; if a native rebuild is forced to VS 2022, inspect the current builder/node-gyp before applying a process-local override.

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
# Write via the file-edit tool: attribution using current model/user, upstream nightly tag,
# local timestamp+UTC offset, full main/build/customization SHAs, Linux SHA256,
# tests actually passed, unsigned status, current installer-identity/updater behavior.
# Do not claim side-by-side isolation unless the merged customization implements it.
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

On retry: inspect existing branch/tag/release; reuse only exact matching SHAs/assets. Never retarget tags or overwrite a published asset silently. Custom tag prefix avoids upstream `v*` release triggers. No PR is part of this build workflow.

Report release URL, installer path/name, version, main/build SHAs, checks, installation/update caveats, **pushed**, **worktree is clean**. Register PRs only if separately requested; do not create one for a build.

Skill maintenance checks: `pwsh -NoProfile -File tests/git.tests.ps1`; `pwsh -NoProfile -File tests/build.tests.ps1`; `bash -n scripts/linux-build.sh`; `bash -n scripts/wsl-smoke.sh`. Tests use local fixtures/mocks; they never sync the real fork or publish a release.
