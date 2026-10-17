---
name: t3-code-custom-build
description: Sync T3 Code, merge customizations, build Windows x64 with WSL, and publish an AS Custom release.
disable-model-invocation: true
---

# T3 Code AS Custom

PowerShell 7; Windows x64; Linux Docker daemon. Resolve `$Skill` from the loaded skill's base directory and `$Repo` from the target T3 Code checkout.

Run each stage separately; use the printed `run.json` path as `$Run`. State persists across shell calls.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Sync -Repo $Repo
& "$Skill/scripts/workflow.ps1" -Stage Merge -Run $Run
& "$Skill/scripts/workflow.ps1" -Stage Build -Run $Run
```

- `Sync`: merge upstream main into local/fork main; freeze latest upstream nightly's base version and local timestamp.
- `Merge`: update every local/remote `customizations/*` with main; merge frozen customization SHAs into `custom_builds/yyyy_MM_dd_HH_mm`; push.
- `Build`: stamp matching versions, build Windows/client and Linux x64 runtime, smoke-test Linux, bundle WSL into NSIS. Optional native WSL check: add `-WslDistro <installed-distro>`.

Conflicts are agent work: resolve and commit in the printed worktree, validate affected code, then rerun the failed stage automatically. Do not hand conflicts back to the user. Preserve divergent history; no force-push.

Build timeout ≥900000 ms. Logs and retained Docker container name are under the run's scratch directory. Check active processes/container before retrying `Build`.

Read `run.json`; write release notes to `$NotesFile`: upstream nightly tag, timestamp/offset, main/build/customization SHAs, Linux archive SHA256, passed checks, unsigned status, actual installation/update behavior.

```pwsh
& "$Skill/scripts/workflow.ps1" -Stage Publish -Run $Run -NotesFile $NotesFile
```

`Publish`: upload renamed installer + `SHA256SUMS` to a draft fork prerelease; verify downloaded bytes and tag target; publish without marking latest. Existing tag/release: inspect and reconcile matching inputs before resuming publication.

Report release URL, installer path, version, main/build SHAs, checks, installation/update caveats.
