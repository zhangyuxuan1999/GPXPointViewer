# Date persistence — remaining en/de visual acceptance (deepseek-flash/max)

## Status
**Complete for the authorized scope.** Both visual-only phases ran successfully in a single wrapper execution, and **6/6 expected PNGs were produced**. No functional checks were executed. Pixel content was **not** judged; that remains for root review.

## Execution discipline
- Read the frozen config and wrapper before acting; confirmed only two phases: `visual-en` and `visual-de`, both `visual-only`, zero functional assertions.
- Confirmed the driver readiness fix exists: wait for `loading is False` and `points == 11` before applying `summarymaindate 2026 10 16 UTC`.
- Confirmed the fresh run directory had no `artifacts/`, so `execution-started.json` did not pre-exist.
- Executed **exactly once**, with no env prefix, no arguments, no redirection, and no sandbox override:
  `python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/coordinator/run-date-acceptance.py`
  Foreground timeout 360000 ms. Wrapper returned success; both phase exit codes were **0**. No retry, no rerun of accepted checks, and no other Bash commands.

`acceptance-execution.json`:
- `all_requested_completed=true`
- `passed=true`
- `old_functional_suite_rerun=false`
- `actual_bill=null`
- `pixel_verdict=PENDING_MAIN_AGENT_REVIEW`
- `literal_keyboard_verdict=PENDING_SEPARATE_MISSING_EVIDENCE_CHECK`

## Actual phase results

| Phase | Language | Start → Finish (UTC) | Driver PID | Exit | Functional checks | App quit |
|---|---|---|---|---|---|---|
| visual-en | en | 2026-10-31T02:50:26.558726 → 02:50:34.362960 | 56401 | 0 | 0 executed / 0 failed | normal, exit 0 (app pid 56434) |
| visual-de | de | 2026-10-31T02:50:34.363338 → 02:50:42.054535 | 56609 | 0 | 0 executed / 0 failed | normal, exit 0 (app pid 56654) |

Both phases:
- `execution-result.json`: `completed=true`, `functional_checks_executed=0`, `functional_checks_failed=0`.
- `results.json`: `[]`.
- Driver stdout: `VISUAL_ONLY functional_checks=0`; stderr empty.
- Readiness proven by state hook 009: `ready=true`, `totalPoints=11`, `filterPoints=2`, `selectedDay="2026-10-16"`, `builds=1` — fixture import completed before date setup.
- Post-All-data state hook 014: `selectedDay=""`, `totalPoints=11`, `currentDay={}`.

## Generated PNGs (6/6; existence and non-zero size asserted by the driver)
1. `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T025004.726652Z_date-visual-en-de-remaining_165fded7/artifacts/visual-en/20261031T025026.657076Z-6336cfb5/main-selected-16.png`
2. `.../artifacts/visual-en/20261031T025026.657076Z-6336cfb5/choose-date.png`
3. `.../artifacts/visual-en/20261031T025026.657076Z-6336cfb5/cross-midnight-journey-top.png`
4. `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T025004.726652Z_date-visual-en-de-remaining_165fded7/artifacts/visual-de/20261031T025034.450155Z-0fee0037/main-selected-16.png`
5. `.../artifacts/visual-de/20261031T025034.450155Z-0fee0037/choose-date.png`
6. `.../artifacts/visual-de/20261031T025034.450155Z-0fee0037/cross-midnight-journey-top.png`

Shot hooks report: English 1696x1320, 1696x1320, 1784x1408; German all 1696x1320. This is capture metadata only — **no pixel verdict**.

## Build identity (identical in both phase provenance files)
- App: `/private/tmp/GPXPointViewer-20261031T022013Z_release_622cc5f4-41jxc2qk/archive/GPXPointViewer.app`
- Manifest: `/private/tmp/GPXPointViewer-20261031T022013Z_release_622cc5f4-41jxc2qk/archive/build-manifest.json`
- Executable SHA-256: `eb52d08767443f1d1ee967b994f485731785e111685bef903688366bb8884265`
- Source SHA-256: `d22ea9dc6cd7c993429da024b03e99d2958b3bb4a4d6f7f67a08f459ecd401ab`
- Source association: `build-completed-between-identical-input-snapshots`
- Manifest: `signing_policy=sandboxed-local`, `installable=true`
- Driver SHA-256: `901ba4f0ad7b89dac990be323735f9fe28ff5a0d0d56886c419d6e0caad3b63b` (wrapper assertion passed)
- Config-referenced durable archive: `/Users/zyx/Documents/GPXPointViewer/Builds/20261031T022013Z_release_622cc5f4/archive/` (zip + manifest); isolated test copies were derived from the verified build.

## Cleanup and isolation
- Both owned app processes exited normally with code 0; no failure cleanup.
- Unique isolated bundles only:
  - `de.wayne.GPXPointViewer.test.t20261031t025026z-fde3c5b39aee` (en)
  - `de.wayne.GPXPointViewer.test.t20261031t025034z-76d564411549` (de)
- `formal_preference_domain_accessed=false`, `formal_app_process_touched=false`; isolated domains retained for evidence.
- `execution-started.json` exists (single-run protection consumed).
- Temporary display assertion: `caffeinate -d -u -t 1200`, pid 56400. The wrapper’s `finally` terminates it before writing `acceptance-execution.json` and exiting; the completed run therefore implies that cleanup path ran. No separate `ps` check was run, as no other Bash command was authorized.
- Previous failed run `20261031T022543...` and its artifacts remain untouched.

## Inheritance (not rerun)
Accepted prior evidence remains inherited: 6 navigation checks, 4 settings A/B/C checks, 44 Store evidence, and the new literal-keyboard Return/View check. This run executed zero functional checks and did not rerun any of them.

## Pending / not done
- **Pixel review:** `PENDING_MAIN_AGENT_REVIEW` — root must inspect the 6 saved PNGs.
- **Literal keyboard + single Return/View flush:** `PENDING_SEPARATE_MISSING_EVIDENCE_CHECK` — not produced by visual-only mode.
- Actual provider model and billed cost: **unknown/null**.
- No source edits, formal app launch/installation, real preference access, or credentials use.

Progress was persisted at start and completion in:
`/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T025004.726652Z_date-visual-en-de-remaining_165fded7/progress.md`