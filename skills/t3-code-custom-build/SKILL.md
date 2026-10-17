---
name: t3-code-custom-build
description: Sync T3 Code, merge customizations, build Windows x64 with WSL, and publish an AS Custom release.
disable-model-invocation: true
---

# T3 Code AS Custom

PowerShell 7; Windows x64; Linux Docker daemon. Resolve `$Skill` from the loaded skill's base directory and `$Repo` from the target T3 Code checkout.

**First: check upstream overlap.** Fetch current `pingdotgg/t3code:main` and remote `customizations/*` without merging or pushing. Compare each customization's behavior with upstream, not just commit ancestry. For full or partial overlap, show evidence and ask whether to keep, skip this run, or remove it; wait for the answer before Sync/Merge/Build. Remove branches only with explicit approval. Set `$SkipBranches` to approved per-run exclusions (an empty array otherwise).

Run each stage separately; use the printed `run.json` path as `$Run`. State persists per branch; worktrees and package caches live beside the repository's Git data.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Sync -Repo $Repo -SkipBranches $SkipBranches
& "$Skill/scripts/workflow.ps1" -Stage Merge -Run $Run
& "$Skill/scripts/workflow.ps1" -Stage Build -Run $Run
```

- `Sync`: merge upstream main into local/fork main; freeze latest upstream nightly's base version and local timestamp.
- `Merge`: fetch every remote `customizations/*` locally, update selected branches with main, merge into `custom_builds/yyyy_MM_dd_HH_mm`; push. Exclude approved skips and local-only/deleted remote branches; skips persist in `run.json`.
- `Build`: stamp matching versions, build Windows/client and Linux x64 runtime, smoke-test Linux, bundle WSL into NSIS. Optional native WSL check: add `-WslDistro <installed-distro>`.

Conflicts are agent work: resolve and stage in the printed worktree, then rerun the failed stage automatically; it commits using recorded merge parents without repository hooks. Format only resolved files; validate affected code in the integrated build worktree instead of installing dependencies in disposable merge worktrees. Do not hand conflicts back to the user. Preserve divergent history; no force-push.

Build timeout ≥900000 ms. Timed milestones identify dependency installation, compilation and packaging. Logs and retained Docker container name are under the run's scratch directory; Linux tools/package/Cargo caches use the reusable `t3-as-custom-linux-cache` volume. Check active processes/container before retrying `Build`.

Read `run.json`; write release notes to `$NotesFile`: upstream nightly tag, timestamp/offset, main/build/customization SHAs, skipped branches, Linux archive SHA256, passed checks, unsigned status, actual installation/update behavior.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Publish -Run $Run -NotesFile $NotesFile
```

`Publish`: upload renamed installer + `SHA256SUMS` to a draft fork prerelease; verify downloaded bytes and tag target; publish without marking latest. Retry the same command to resume matching tags/releases; mismatched inputs stop publication.

Report release URL, installer path, version, main/build SHAs, checks, installation/update caveats.
