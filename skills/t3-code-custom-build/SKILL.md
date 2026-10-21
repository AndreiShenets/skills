---
name: t3-code-custom-build
description: Sync T3 Code, merge customizations, build Windows x64 with WSL, and publish an AS Custom release.
disable-model-invocation: true
---

# T3 Code AS Custom

PowerShell 7; Windows x64; Linux Docker daemon. Resolve `$Skill` from the loaded skill's base directory and `$Repo` from the target T3 Code checkout.

**First: check upstream overlap, before Sync/Merge/Build.**
1. Fetch current `pingdotgg/t3code:main`, upstream release tags, and remote `customizations/*` without merging or pushing. For each customization, search merged upstream PRs and published releases (including nightlies) for equivalent fixes/features. Consider issues only as pointers to merged, released implementations; exclude open PRs and closed-unmerged PRs from the overlap check and report.
   Use the [shared overlap cache workflow](references/caching.md#overlap-research): load its review plan before research, inspect upstream/release deltas, and save verified evidence before Sync. Reuse still-accurate descriptions and evidence; cached classifications never authorize an exclusion, and approvals remain per run.
2. Count a customization as fully replaced only when merged upstream code covers all its required behavior, is included in a published upstream release, and remains present in current upstream main. Verify code and release inclusion; issue closure, PR merge status, and commit ancestry alone do not prove equivalence. Account for partial implementations and reverts.
3. Keep customizations with partial, absent, unreleased, or unverified coverage automatically; save per-customization findings for release notes and continue without requesting confirmation. If none are fully replaced, proceed directly to Sync/Merge/Build without an interim overlap report.
4. Only for fully replaced customizations, report merged PR/release links and code evidence, then ask whether to keep, skip this run, or remove them; wait for the answer before proceeding. Remove branches only with explicit approval. Set `$SkipBranches` to approved per-run exclusions (an empty array otherwise).

Run each stage separately; use the printed `run.json` path as `$Run`. New runs resolve the main Git checkout and share its ignored `release/as-custom/`: `runs/<run>/` holds state, logs and checkpoints; `cache/` holds overlap/package caches; `<run>/` holds the build worktree. Starting from a linked/detached/nested checkout uses the same root; see [cache resolution and reuse](references/caching.md). Existing runs retain recorded recovery paths. Vite blocks build worktrees beneath `.git`; for an older build worktree there, use `git worktree move` and update `Work` in `run.json` before resuming Merge/Build.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Sync -Repo $Repo -SkipBranches $SkipBranches
& "$Skill/scripts/workflow.ps1" -Stage Merge -Run $Run
& "$Skill/scripts/workflow.ps1" -Stage Build -Run $Run
```

- `Sync`: merge upstream main into local/fork main; freeze latest upstream nightly's base version and local timestamp.
- `Merge`: fetch every remote `customizations/*` locally, update selected branches with main, merge into `custom_builds/yyyy_MM_dd_HH_mm`; push. Exclude approved skips and local-only/deleted remote branches; skips persist in `run.json`.
- `Build`: install dependencies and stamp matching versions, then gate compilation on formatting/lint for changed files, affected-package typechecks, and focused tests. Checks compare the integrated source with the frozen main SHA and write `preflight.log`; rerun checks archive prior logs as `preflight.attempt-NNNN.log`. Browser/live tests, including unchanged siblings of modified source, are listed for separate authorized verification. Build Windows/client and Linux x64 runtime, smoke-test Linux, bundle WSL into NSIS. Optional native WSL check: add `-WslDistro <installed-distro>`.

T3 Connect is enabled automatically using the build checkout's `.env.example` public identifiers. Overrides take precedence: process environment, build checkout `.env.local`/`.env`, then source `$Repo` `.env.local`/`.env`; canonical and framework aliases are accepted. Only the four Connect public identifiers are imported from those files for Windows compilation/packaging and the Linux container. Missing/invalid configuration stops before dependency installation. Config changes invalidate artifact checkpoints; a retained container with different config requires a new run ID. Env files remain untouched, and the caller's environment is restored after compilation/packaging.

Retries reuse preflight results, Windows compilation, Linux archives and installers only when stage-specific source/version/base/config/tooling inputs and output hashes match. A verified final-artifact retry skips dependency installation; other retries run the frozen install with the shared store. Use `Build -Rebuild` to force every check/build step, including fresh Rust compilation. Failed checks stop compilation/packaging. Commands use the build worktree's Vite+ Node entry point and bounded file batches, preserving PowerShell pass-through arguments and long Windows file lists. First install can bootstrap from `$Repo`'s installed Vite+ or a global native `vp`.

Conflicts are agent work: resolve and stage in the printed worktree, then rerun the failed stage automatically; it commits using recorded merge parents without repository hooks. Format only resolved files; validate affected code in the integrated build worktree instead of installing dependencies in disposable merge worktrees. Do not hand conflicts back to the user. Preserve divergent history; no force-push.

Commit reusable fixes to their owning `customizations/*` branches as well as the integrated build; build-only fixes disappear from future runs.

Build timeout ≥900000 ms. Timed milestones identify dependency installation, compilation and packaging. Logs, checkpoints and failed-run Docker resources remain available for recovery; Linux reuses a prepared prerequisite image and tools/package/Cargo target caches in `t3-as-custom-linux-cache`. Check active processes/container before retrying `Build`.

Read `run.json`, `preflight.log`, and [the release-note contract](references/release-notes.md). Record agent-verified findings/descriptions in `$FindingsFile` using that contract's JSON shape, then generate the notes. Reuse still-accurate approved descriptions; generation cannot judge upstream equivalence or confirm human approval. Preview the generated Markdown and complete the semantic pre-publication checklist.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Notes -Run $Run -FindingsFile $FindingsFile
& "$Skill/scripts/workflow.ps1" -Stage Publish -Run $Run
```

`Notes` saves the findings and generated `release-notes.md` under the run scratch directory. `Publish` verifies the artifact checkpoint and regenerates the expected notes before uploading the renamed installer + `SHA256SUMS` to a draft fork prerelease. It verifies downloaded bytes, tag target and release body, then publishes without marking latest. Mismatched inputs stop publication; edit the findings and rerun `Notes` rather than hand-editing the Markdown. Older runs without checkpoints must rerun `Build` and `Notes` first.

After verified publication, remove only this run's stopped Docker container and its verified `/build` volume. Keep the shared cache, artifacts, worktree and logs. Failed/unpublished runs are retained. Cleanup failures set `CleanupPending` without losing `ReleaseUrl`; repeat `Publish` to retry cleanup without reuploading. Active/mismatched containers and unverified orphan volumes require investigation, not forced removal or pruning.

Report release URL, installer path, version, main/build SHAs, checks, installation/update caveats. Link to the release notes for overlap findings.
