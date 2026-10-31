# Independent frozen Store/UI review

Review complete. **Both actionable P2 findings were fixed; no outstanding concrete product defect found in the reviewed final scope.** Provider succeeded; coordinator acceptance pending. First Xcode Release build and actual UI/pixel acceptance remain separate root work. This review makes no release/visual-pass claim and does not reopen the completed core review.

Requested model: GPT-6.1 Sol / ultra. Observed server model, tokens and actual cost are unknown/null. Reviewer performed read-only source review, snapshots, diffs and inheritance/assessment of author evidence. **No tests, builds, app launches, UI execution, network or product/test edits by reviewer.** Only this review run was written.

## Findings and resolution

### STORE-R1 — P2, fixed: single-day summary filter chip hidden

Original `ContentView.swift` SHA `4bfa40edc35a876dd01c6cefa90f3e714f22463e06b02156483d379817d9d1f6`, lines1497-1510, rendered the entire TimeFilterSection only when first/last track timestamps belonged to different `Calendar.current` days. A normal single-local-day track could apply a valid journey summary filter, yet its truthful source/time-zone chip and clear control were hidden. Main-map points would be filtered with no main-panel indication or clear action. Existing Store checks only asserted selection state and never rendered this parent guard.

Author fixed the guard to admit active `summaryFilterSelection` independently of the old multiple-day condition. Final ContentView SHA `022392d9f9f351612a896273e39e069bb12bc0bd6f7557d9a77ee74199858e85`; exact diff is captured in `artifacts/capture/commands/20261030T052300_fix-deltas-store-content_56c06d68/stdout.log`. Static resolution accepted; final fresh-compilation evidence includes this exact guard. Actual single-day chip rendering, clickability and clearing are covered by the newly prepared root UI harness, **not executed or pixel-accepted by reviewer**.

### STORE-R2 — P2, fixed: public one-file mode switch left summary absent

Original `TrackStore.swift` SHA `07750f7942fe34c38994491816b7dd8f6770ce5cc8b52bf2182e86b74ce5f2b0`: displayMode observer invalidated summary, but public `switchDisplayMode(to:)` lines702-730 did not schedule refresh. With one file and an open completed summary, single→overlay or overlay→single preserved track ID, had compareTracks already nil and produced no loading/fills/track callback. The report stayed absent until an unrelated ensure/reopen/time-zone action. Existing source tests manually called ensure and masked this event-wiring gap.

Author added deferred `scheduleSummaryRefresh()` at the end of `invalidateDataOperations()`, guarded by window-open/input readiness when the queued callback runs. Final TrackStore SHA `c2382edbcc8730068de23e8497ce9dfb086bc7630ee8c8a874e656b73494add6`. Reviewed deferred scheduling, cache/request deduplication and mutation ordering. New author `modeentry` group calls the public switch in both directions without manually ensuring and proves exactly one replacement build each time; fresh compilation/run exit0, five checks passed. Source resolution and directed evidence accepted.

## Review scope and important evidence limits

Read the accepted design/rules (identical SHA to already-read current context), complete SummaryWorkSnapshot/State, SummaryWindow and summary Store extension; owning track/files/mode/fills/compare invalidation observers and commit order; publication lane/clock; map guards, half-open end.nextUp, dateline handling and filter reset; ContentView parent guards, TimeFilterSection chip and initSpan/push guards; app shared Store/scene/commands; UITestHook; actual Xcode Sources membership; new Store regression source/runner and prepared UI harness. Read summary translations in `chunk_31.json` as static resource text; no localization completeness test or pixel execution performed.

Adapter review: arrays remain CoW values; segment ranges are small copied values; fill provenance scan runs on worker and distinguishes retimed positions from synthetic coordinates, with synthetic precedence left to core. Overlay selects fileID subset; compare selects actual pane TrackData, with nil while panes not ready. Publication validates document token, request UUID, cache key and actual input track identity. RegionIndex.shared is a static immutable identity, so captured identity cannot drift at runtime. Same-source time-zone changes preserve overrides; actual track/source change clears them as specified. Main-map filter/settings remain outside key, provenance revision invalidates same-count replacements, closed-window tasks lose ownership, stale success/failure cannot clear newer busy state.

UI review: unknown/unavailable states, recorded/estimated labels, conservative mode candidates and manual override/reset are present; day transport renders related journeys without confirming one all-day mode. SummaryWindow has scrollable detail and wrapping text with minimum780×560, source and zone controls, and accessibility identifiers. These source choices do not prove German/Chinese small-window layout, focus/clickability, actual menu scene behavior or screen pixels. Xcode main target contains all three new Swift sources; neither extension Sources phase includes them. Standalone Store compilation typechecks SwiftUI sources with test entrypoint, but is not a signed/archived main-target build and does not validate resources/catalog packaging.

Prepared UI harness was inspected, not executed: explicit manifest-verified GPXPV_APP, unique copy/communication directory, owned child process only, saved/restored preference bytes, local GPX/region fixtures, fake tiles, one single-local-day/two-journey chip regression, UTC midnight fixture, endpoint inclusion, mode/source/untimed checks, small-window top/lower captures and visual-only language path. Root remains responsible for actual run, cleanup/manifest inspection and pixel verdict.

## Inherited evidence: original53 plus new12 plus new5

Author evidence base: `../20261030T042612.249638Z_journey-summary-store-ui_4746c6f6/artifacts/store-tests/`.

| Directory | Verified original evidence |
|---|---|
| `20261030T045736.378965Z-411e38bd` |Original53 checks,0 failures; compile exit0/run exit0, empty run stderr, source-stability all true. Exact original/compiled source SHA matches initial review snapshot. Tests cover cache/manual/time-zone/reopen, overlay/compare, gated stale success/failure/close/clear, map endpoints/guards and worker provenance/same-count invalidation. These are inherited original-source results, not newly rerun on final files. |
| `20261030T050426.512371Z-646b29e3` |First new lifecycle group,12 checks/0 failures; fresh compile0/run0, source-stability true. Final Store SHA c2382edb. Covers autonomous mode invalidation, changed effective time-zone clearing old chip, dateline no-flight/exact filter and UI tab state. Some UI-hook/layout files predate final-only refinements; this evidence is scoped to tested Store behavior. |
| `20261030T050707.228697Z-9a9bc11d` |First new public modeentry group,5 checks/0 failures; fresh compile0/run0, source-stability true. Includes final Store/ContentView/ExportSheet/Window/hook/test SHAs listed below. Public single↔overlay one-file transitions refresh without manual ensure or track ID change. |

Total70 recorded passing checks across these3 retained runs, including repeated readiness checks; **not70 distinct independent scenarios** and not a full final rerun. Original53 were not repeated. Runner removes application @main and Store access restrictions in a separately saved test copy; algorithms and production methods are unchanged. Original and compiled hashes/transformation declarations were inspected. `--binary` is not source-manifest-checked by this runner, but **neither new directed run used it**; both have fresh compile command/result and correct binary path. No stale-binary claim accepted. Raw metadata/stdout/stderr, relevant compiled sources and copy SHA manifests retained under `artifacts/inherited-original53/` and `artifacts/inherited-directed/`.

## Final source identity

Exact full snapshots/manifests: `artifacts/source-20261030T050302-1567d8c8` (original) and `artifacts/source-20261030T050739-50fe612f` (fixed); final live hash read at05:23:53 matches fixed snapshot. Relevant final identities:

| File | SHA256 |
|---|---|
| JourneySummaryState.swift | `dbcb5de0bcc3219ac0c05f352be2c323a8cc97c2fa0d635454354632a4288bf6` |
| JourneySummaryWindow.swift | `8dd746705efe8129e53d13228cd85e936737a45f7726e9b3294e4ffab3010077` |
| TrackStore.swift | `c2382edbcc8730068de23e8497ce9dfb086bc7630ee8c8a874e656b73494add6` |
| ContentView.swift | `022392d9f9f351612a896273e39e069bb12bc0bd6f7557d9a77ee74199858e85` |
| ExportSheet.swift | `2a0895b759ba3c360585c3662e587a206209264fbbb6d0bcc82375d11bc183d9` |
| UITestHook.swift | `9fc233473040b39b93daaa876bdf33a29a35d112d074293ad5499493e56eb3fc` |
| ChangeLog.swift | `559fabd1452478d51dfb20c298b1a7df918e6a3bbf1129e8b14c411a5d141d3b` |
| GPXPointViewerApp.swift | `c85cc151d492c5aa50b50bf5b699316c70e1c952e6e314852b582345032aaa15` |
| project.pbxproj | `bca06920cdb7ba108ac9f9738905a01c42519a26844dd84503364d3bcc0517f8` |
| StoreRegression.swift | `994c09b1d66481080115d2c1475f09d4e804cf83da4ade024768e83b65bf7aa3` |
| Store run.py | `0cf0d3b3c9ea2ca0831824c361636d4e02de1a7bc74b613831bba84b5b0b8049` |
| UI run_summary_tests.py | `8508a9a037ddb761668cff8958668978e631c8db4614d4748b7e3a7c68beb949` |

Full commands/tool stdout/stderr/real exits are in `artifacts/capture/`; multiline script bodies were saved before invocation. Exact actionable finding messages and author follow-ups are in `artifacts/messages/`. This review did not independently execute passed work.
