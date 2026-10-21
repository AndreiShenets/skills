# Shared build caches

## Root resolution

`Get-MainCheckoutDirectory` in `scripts/progress.ps1` uses Git's main worktree entry, not the current branch, working directory or `.git` file's parent. `Get-BuildCacheDirectory -Worktree $Repo` returns `<main-checkout>/release/as-custom/cache`. Main, linked, detached and nested build/merge checkouts share it. A missing main checkout stops resolution instead of creating an accidental worktree-local cache. Independent clones have independent roots.

New run state, build worktrees and artifacts also live under the main checkout's `release/as-custom/`. Existing runs retain recorded recovery paths. Logs print both run and cache paths.

## Overlap research

After fetching upstream main, upstream release tags and `origin/customizations/*`, resolve the reviewed upstream main to `$UpstreamSha`, the latest published nightly tag to `$NightlyTag`, and that upstream tag's commit to `$PublishedSha`. Confirm publication through GitHub; a local tag alone is not proof. Keep these frozen throughout the check.

```pwsh
& "$Skill/scripts/overlap.ps1" -Repo $Repo -UpstreamRef $UpstreamSha -NightlyTag $NightlyTag -PublishedRef $PublishedSha
```

Read the printed review JSON. The shared ledger holds descriptions, classifications and immutable evidence, never per-run skips, removals or human decisions. Plans are research hints, not findings accepted by `Notes`.

- **unchanged**: code snapshots match. Confirm publication and current presence; reuse still-accurate wording.
- **delta**: examine the listed upstream commits and main/published file diffs. Search all newly merged PRs and newly published releases since `previousCheckedAt`, including stable releases even when the nightly is unchanged. Use path/keyword matches for prioritization, not as proof of no overlap. Inspect relevant changes semantically, including refactors, dependencies and reverts.
- **full**: research the customization normally. This applies to new/changed customizations, changed verification policy, missing/corrupt cache, unavailable history and non-descendant upstream snapshots.

Every plan requires agent verification. An unchanged snapshot still needs new-release discovery; no scope authorizes an exclusion. Retain uncertain/partial/unreleased customizations. Full coverage still requires all required behavior to be merged, published and present on main, followed by this run's explicit keep/skip/remove decision.

After verification and any required user decisions, write `$FindingsFile` in the [release-note input shape](release-notes.md#generation-input), then save the reusable evidence:

```pwsh
& "$Skill/scripts/overlap.ps1" -Action Save -Repo $Repo -UpstreamRef $UpstreamSha -NightlyTag $NightlyTag -PublishedRef $PublishedSha -FindingsFile $FindingsFile
```

Save again from the final run findings after `Notes` if merging changed customization SHAs or descriptions. The ledger is atomically replaced under an exclusive writer lock; concurrent readers see a complete old or new snapshot. A busy writer stops Save; retry Save rather than losing findings. Failed builds leave research available for the next run. No branch changes or network calls are performed by this helper.

## Build reuse

- Windows compilation has its own source/config/tooling key and a hashed complete output inventory. Packaging failures can reuse it; missing/added/changed outputs force compilation.
- Preflight, Windows, Linux and installer keys include only their relevant helper scripts. Release-note or overlap-helper edits do not invalidate compilation.
- A fully verified final-artifact retry skips dependency installation. Any work requiring dependencies still runs the frozen install against the shared store; a lockfile alone does not prove an installed tree is intact.
- Linux prerequisites are installed once in a versioned prepared Docker image. Builds and checkpoint keys use its immutable image ID. Changed helpers/tooling cannot resume an incompatible container.
- Docker's `t3-as-custom-linux-cache` volume remains daemon-local and shared. Rust target outputs are additionally namespaced by the resolved main-repo cache root and toolchain, with locking through build/copy. Cargo still checks freshness with `--locked`; this is a compilation cache, not blind executable reuse.
- `Build -Rebuild` bypasses checkpoints and forces fresh Rust target outputs for that run. Run-specific sources, containers and `/build` volumes remain isolated. Publication cleanup preserves shared caches and the prepared image.

Artifact checkpoints remain per run; new runs share research, downloads and Rust compilation caches, not another run's installer or approvals.

## Recover a retained container

Upgrading the skill can invalidate a retained Linux container (including legacy containers without `LINUX_BUILD_INPUTS`). Keep the same `run.json` and build branch: reset only that run's stopped container and private `/build` volume, then retry `Build`. Successful Windows/preflight checkpoints can still be reused.

Inspect and validate first; these checks mirror publication cleanup. If any check fails, investigate rather than removing resources.

```pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$State = Get-Content -LiteralPath $Run -Raw | ConvertFrom-Json
if ($State.RunId -notmatch '^\d{4}_\d{2}_\d{2}_\d{2}_\d{2}$') { throw 'Invalid run ID' }
$Name = "t3-as-custom-$($State.RunId.Replace('_', '-'))"
$Container = docker inspect --format '{{json .}}' $Name | ConvertFrom-Json
$Mount = @($Container.Mounts | Where-Object Destination -CEQ '/build')
if ($Container.Name -cne "/$Name" -or $Container.State.Status -notin @('exited', 'created') -or
    $Container.Config.Env -cnotcontains "BUILD_SHA=$($State.BuildSha)" -or
    $Container.Config.Env -cnotcontains "BUILD_VERSION=$($State.Version)" -or
    $Mount.Count -ne 1 -or $Mount[0].Type -cne 'volume' -or $Mount[0].Name -cne $Name) {
    throw 'Unverified or active build resources; leave them intact'
}
$Container | Select-Object Name, State, Mounts
```

Show the exact resource names and get explicit user approval before discarding this private Linux build workspace. After approval only:

```pwsh
docker rm $Name
docker volume rm $Name
& "$Skill/scripts/workflow.ps1" -Stage Build -Run $Run
```

Use no force/prune options. Leave `t3-as-custom-linux-cache`, prepared images, source checkouts, artifacts and `run.json` intact. If removal is interrupted or an orphaned volume's ownership cannot be verified, investigate before retrying. This recovery preserves the run ID and does not require a new Sync/Merge.
