# Release-note contract

Match the layout and editorial style of the [approved release](https://github.com/AndreiShenets/t3code/releases/tag/as-custom-v0.1.1-202610191348). The template below is authoritative; the published example supplies wording, not current build facts.

## Writing rules

- Use exactly the three `##` sections in the template, in that order, with its field labels and link labels. Start directly with `## Source`.
- Sort full customization branch names alphabetically. Use the same inventory and order in the table, description headings, and overlap bullets, including approved skips/removals. Display the first 12 SHA characters in table links; link to full frozen commits.
- Under each `###` heading, write one plain-text paragraph of 1–3 short sentences describing concrete behavior. Keep product names, authentication modes, supported surfaces, and important constraints precise. Put evidence links in **Upstream overlap**, leaving feature descriptions link-free.
- Reuse an existing accurate feature description verbatim when behavior is unchanged. Start with the approved release for existing branches; revise only for verified behavior changes or factual corrections. Describe new branches from code/PR evidence, not their names.
- Recheck every overlap finding against the published upstream release and current upstream main on every run. Keep its wording and classification when still supported; change them only with evidence. Related work alone does not establish coverage of required behavior.
- Coverage: **full** = all required behavior is merged, published, and still present on main; **partial** = only some required behavior meets those conditions; **absent** = inspected code verifies the required behavior is missing; **unreleased** = equivalent merged behavior is not yet published; **unverified** = evidence is insufficient. Apply the skill's approval rule for full coverage.
- Each overlap bullet has 1–2 short factual sentences, then `Retained.`, `Skipped.`, or `Removed.`, then evidence links. Use `merged PR #<number>`, `published release`, `published nightly code`, and `current upstream code` as applicable. Cite a published release once in Source when it is the same nightly; link a different release in its bullet. Link code at immutable SHAs or release tags. Include custom code evidence when needed to establish the remaining behavior.
- Keep verification logs, installation guidance, build narration, and additional introductions or conclusions outside the release body. Report checks and caveats in the final build response instead.

## Template

Replace every placeholder. Repeat the table row, description block, and overlap bullet once per customization. For exclusions, replace `All included.` with `Skipped: <full branch names or none>. Removed: <full branch names or none>. All others included.`

```markdown
## Source

- Upstream nightly: [<nightly-tag>](https://github.com/pingdotgg/t3code/releases/tag/<nightly-tag>); base version **<version>**.
- Frozen timestamp: `<ISO-8601 timestamp with offset>`.
- Main: [<main-sha>](https://github.com/AndreiShenets/t3code/commit/<main-sha>).
- Build: `<build-branch>` at [<build-sha>](https://github.com/AndreiShenets/t3code/commit/<build-sha>).
- Skipped branches: <none or full branch names in backticks>.

## Customization inputs

| Branch | SHA |
| --- | --- |
| `customizations/<branch-suffix>` | [<12-character-sha>](https://github.com/AndreiShenets/t3code/commit/<full-sha>) |

### <branch-suffix>

<Concrete behavior paragraph; no links.>

All included.

## Upstream overlap

- **<branch-suffix> — <coverage>.** <Upstream behavior; remaining custom behavior.> Retained. [published nightly code](https://github.com/pingdotgg/t3code/blob/<nightly-tag>/<path>); [current upstream code](https://github.com/pingdotgg/t3code/blob/<upstream-main-sha>/<path>).
```

## Generation input

Supply this JSON to `workflow.ps1 -Stage Notes -Run $Run -FindingsFile <file>`. Repeat `customizations` once per discovered remote branch, including approved skips/removals. Source values and included SHAs come from `run.json`; excluded SHAs are frozen during the overlap check. The generator sorts branches and enforces inventory, dispositions, immutable code evidence and the template. It does not verify the linked code or the truth of an approval.

```json
{
  "upstreamSha": "<run.UpstreamSha>",
  "nightlyTag": "<run.NightlyTag>",
  "customizations": [
    {
      "branch": "customizations/<suffix>",
      "sha": "<40-character frozen SHA>",
      "description": "Concrete behavior paragraph, reused when still accurate.",
      "coverage": "partial",
      "finding": "What upstream covers and what remains custom.",
      "disposition": "retained",
      "evidence": [
        { "label": "published nightly code", "url": "https://github.com/pingdotgg/t3code/blob/<nightly-tag>/<path>" },
        { "label": "current upstream code", "url": "https://github.com/pingdotgg/t3code/blob/<upstream-sha>/<path>" }
      ]
    }
  ]
}
```

- `coverage`: `full`, `partial`, `absent`, `unreleased`, or `unverified`.
- `disposition`: `retained`, `skipped`, or `removed`. Full coverage requires `decision: "keep"`, `"skip"`, or `"remove"`, matching the approved disposition. Skips/removals always require that explicit decision.
- `evidence`: at least `current upstream code` and either `published nightly code` or `published release`. Additional labels: `merged PR #<number>` and `custom code`. Use the frozen main SHA/nightly tag for those code links; encode literal `%` in patch file paths as `%25`.
- Descriptions/findings are plain-text paragraphs; evidence links belong only in `evidence`.
- `Notes` writes `release-notes.md` and a frozen findings copy to the run directory. Optional `-NotesFile` selects another output path. `Publish` rejects edited/stale Markdown; revise the findings and regenerate instead.

## Pre-publication checklist

- Source values match `run.json`, including the timestamp offset and final build SHA. A nightly is a version reference, not necessarily the exact main source used for the build.
- Every discovered remote customization has exactly one table row, description heading, and overlap bullet in matching alphabetical order. Included SHAs match `run.json`'s `Customizations`; excluded SHAs match the inventory recorded during the overlap check. Approved removals stay documented even after remote deletion.
- Source skips and the customization disposition summary match approved exclusions; each overlap disposition agrees. Full coverage has an explicit user decision.
- Summaries retain still-correct details from the approved example or prior accurate notes. Any changed behavior or coverage is supported by this run's evidence, not merely different phrasing.
- Exactly three level-two headings; one two-column table; link-free feature paragraphs; compact overlap bullets with evidence; no unfilled placeholders or extra sections. Preview the Markdown to check spacing and table rendering before Publish.
