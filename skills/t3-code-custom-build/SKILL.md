---
name: t3-code-custom-build
description: Sync T3 Code, merge customizations, build Windows x64 with WSL, and publish an AS Custom release.
disable-model-invocation: true
---

# T3 Code AS Custom

PowerShell 7; Windows x64; Linux Docker daemon. Resolve `$Skill` from the loaded skill's base directory and `$Repo` from the target T3 Code checkout.

**First: check upstream overlap, before Sync/Merge/Build.**
1. Fetch current `pingdotgg/t3code:main`, upstream release tags, and remote `customizations/*` without merging or pushing. For each customization, search merged upstream PRs and published releases (including nightlies) for equivalent fixes/features. Consider issues only as pointers to merged, released implementations; exclude open PRs and closed-unmerged PRs from the overlap check and report.
2. Count a customization as fully replaced only when merged upstream code covers all its required behavior, is included in a published upstream release, and remains present in current upstream main. Verify code and release inclusion; issue closure, PR merge status, and commit ancestry alone do not prove equivalence. Account for partial implementations and reverts.
3. Keep customizations with partial, absent, unreleased, or unverified coverage automatically; save per-customization findings for release notes and continue without requesting confirmation. If none are fully replaced, proceed directly to Sync/Merge/Build without an interim overlap report.
4. Only for fully replaced customizations, report merged PR/release links and code evidence, then ask whether to keep, skip this run, or remove them; wait for the answer before proceeding. Remove branches only with explicit approval. Set `$SkipBranches` to approved per-run exclusions (an empty array otherwise).

Run each stage separately; use the printed `run.json` path as `$Run`. Build worktrees use a short sibling directory outside the repository; logs and package caches remain under its Git data. Vite blocks worktrees beneath `.git`. For an older run there, use `git worktree move` and update `Work` in `run.json` before resuming Merge/Build.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Sync -Repo $Repo -SkipBranches $SkipBranches
& "$Skill/scripts/workflow.ps1" -Stage Merge -Run $Run
& "$Skill/scripts/workflow.ps1" -Stage Build -Run $Run
```

- `Sync`: merge upstream main into local/fork main; freeze latest upstream nightly's base version and local timestamp.
- `Merge`: fetch every remote `customizations/*` locally, update selected branches with main, merge into `custom_builds/yyyy_MM_dd_HH_mm`; push. Exclude approved skips and local-only/deleted remote branches; skips persist in `run.json`.
- `Build`: install dependencies and stamp matching versions, then gate compilation on formatting/lint for changed files, affected-package typechecks, and focused tests. Checks compare the integrated source with the frozen main SHA and write `preflight.log`; retries archive prior logs as `preflight.attempt-NNNN.log`. Failures stop before compilation or packaging. Browser/live tests, including unchanged siblings of modified source, are listed for separate authorized verification. Build Windows/client and Linux x64 runtime, smoke-test Linux, bundle WSL into NSIS. Optional native WSL check: add `-WslDistro <installed-distro>`.

Conflicts are agent work: resolve and stage in the printed worktree, then rerun the failed stage automatically; it commits using recorded merge parents without repository hooks. Format only resolved files; validate affected code in the integrated build worktree instead of installing dependencies in disposable merge worktrees. Do not hand conflicts back to the user. Preserve divergent history; no force-push.

Commit reusable fixes to their owning `customizations/*` branches as well as the integrated build; build-only fixes disappear from future runs.

Build timeout ≥900000 ms. Timed milestones identify dependency installation, compilation and packaging. Logs and retained Docker container name are under the run's scratch directory; Linux tools/package/Cargo caches use the reusable `t3-as-custom-linux-cache` volume. Check active processes/container before retrying `Build`.

Read `run.json` and `preflight.log`; write concise release notes to `$NotesFile` with exactly these `##` sections, in order:

- **Source**: upstream nightly link/base version, frozen timestamp/offset, main SHA, build branch/SHA, skipped branches (or `none`).
- **Customization inputs**:
  - Two-column table, `Branch | SHA`: one row per discovered remote customization, including approved skips/removals. Show full branch names and short SHAs linked to full commits.
  - Immediately below, one `### <branch suffix>` heading per row in the same order. Follow each heading with a blank line and a short paragraph describing concrete behavior from code/PR evidence.
  - End with `All included.` or list skipped/removed branches; all others are included.
- **Upstream overlap**: one compact bullet per customization in table order: `**<branch suffix> — <coverage>.** <upstream behavior; remaining custom behavior>. <retained/skipped/removed>.` Coverage: full, partial, absent, unreleased, or unverified. Link merged PRs, published releases, and code evidence where available; distinguish verified absence from uncertainty.

Keep verification logs, installation guidance, and build narration out of release notes. Before publishing, match both customization sections against the frozen inputs and approved exclusions.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Publish -Run $Run -NotesFile $NotesFile
```

`Publish`: upload renamed installer + `SHA256SUMS` to a draft fork prerelease; verify downloaded bytes and tag target; publish without marking latest. Retry the same command to resume matching tags/releases; mismatched inputs stop publication.

Report release URL, installer path, version, main/build SHAs, checks, installation/update caveats. Link to the release notes for overlap findings.
