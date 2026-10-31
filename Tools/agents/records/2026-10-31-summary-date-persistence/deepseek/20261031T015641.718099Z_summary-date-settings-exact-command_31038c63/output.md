# Date UI and settings acceptance — execution report (exact-command recovery)

Run dir: `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T015641.718099Z_summary-date-settings-exact-command_31038c63`

## Dispatch
- Command executed **exactly once**, unmodified: `python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/coordinator/run-date-acceptance.py`
- No environment-assignment prefix, no `env`, no redirection, no extra arguments, no `dangerouslyDisableSandbox`. Background task `bujfxf0zk`, timeout 360000; completion notification received.
- The earlier rejected modified calls were not repeated.
- Wrapper exit code: **1**. `execution-started.json` was written, consuming the single-execution guard. No retries performed.

## Exact build under test
- App: `/Users/zyx/Documents/GPXPointViewer/Builds/20261031T015341Z_release_e8e131ea/archive/GPXPointViewer.app`
- Manifest: `/Users/zyx/Documents/GPXPointViewer/Builds/20261031T015341Z_release_e8e131ea/archive/build-manifest.json`
- Executable SHA-256: `76578d2a74fd5549de967f7fef92dbf1b78af82525395b8a6734aae9882cec30`
- Source SHA-256: `ad6b4f54617f6021eda1d08ae165146cb753f06e48b2b58e42a8f0699b985cff`
- Driver SHA-256 checked inside wrapper: `d282a7ff41956d33a5b1a9dd7e5359b10f8fbcf8fc48b372fc70d10e8689bd90` (assertion passed; execution reached prepare).

## Phase-by-phase actual outcome
| Phase | Mode/language | Actual exit | Result |
|---|---|---|---|
| `settings-abc` | persistence / none | **1** | Failed in isolated signed-copy **prepare**; app never launched |
| `navigation-zh` | navigation / zh-Hans | **not started** | Wrapper broke after first nonzero phase |
| `visual-en` | visual-only / en | **not started** | No execution |
| `visual-de` | visual-only / de | **not started** | No execution |

- `settings-abc`: started `2026-10-31T01:56:49.404386+00:00`, finished `2026-10-31T01:56:49.640517+00:00`, pid 30154. `stdout.txt` empty; `stderr.txt` = `Isolated signed copy preparation failed; original archive was not launched`.
- Screenshots: **0** (`**/*.png` found none). No `isolated-copy/**` contents remained, and no user-copy domains were created.
- `acceptance-execution.json`: `all_requested_completed=false`, `passed=false`, `old_functional_suite_rerun=false`, `pixel_verdict=PENDING_MAIN_AGENT_REVIEW`, `literal_keyboard_verdict=PENDING_SEPARATE_MISSING_EVIDENCE_CHECK`, `actual_bill=null`.

## Exact failure (retained, for root bounded recovery)
Prepare step invoked:
`python3 Tools/archive_build.py <archive/GPXPointViewer.app> --prepare-isolated-test-copy --destination <.../isolated-copy>`

`prepare.result.json`: `{"exit_code": 1}`. `prepare.stderr.txt`:
```
ValueError: Signature check failed: /Users/zyx/Documents/GPXPointViewer/Builds/20261031T015341Z_release_e8e131ea/archive/GPXPointViewer.app
--prepared: .../Contents/PlugIns/GPXQuickLook.appex
--prepared: .../Contents/PlugIns/GPXThumbnail.appex
GPXPointViewer.app: resource fork, Finder information, or similar detritus not allowed
In subcomponent: .../Contents/PlugIns/GPXQuickLook.appex
```
Classification: **prepare/codesign-validation failure caused by extended-attribute/Finder-info detritus in the signed archive**, not a functional acceptance result. The original archive was explicitly not launched. This run must not be retried; root should separately record a bounded recovery (e.g., compliant rebuild/re-sign then a new recorded run).

## Evidence paths (all preserved)
- `artifacts/execution-started.json` (utc `2026-10-31T01:56:49.402181+00:00`)
- `artifacts/display-assertion.json` (pid 30153, `/usr/bin/caffeinate -d -u -t 1200`, temporary)
- `artifacts/settings-abc/command.json`, `result.json`, `stdout.txt`, `stderr.txt`
- `artifacts/settings-abc/20261031T015649.482508Z-a5f14084/{prepare.command.json,prepare.stdout.txt,prepare.stderr.txt,prepare.result.json,source-build-provenance.json,execution-mode.json}`
- `artifacts/acceptance-execution.json`
- `progress.md` (start and finish updated)

The wrapper's `finally` executed (display assertion terminated before `acceptance-execution.json` was written); no independent process probe was run. Evidence was not cleaned or modified.

## Verdicts and remaining pending items
- Settings persistence: **NOT PASSED / NOT EXECUTED** — preparation failed; no 3-process readback, so settings cannot be claimed passed.
- Navigation zh-Hans and visual en/de: **NOT EXECUTED**; zero screenshots, so nothing can be marked visually good.
- Pixel verdict: **PENDING_MAIN_AGENT_REVIEW** (no images).
- Literal keyboard typing: **PENDING_SEPARATE_MISSING_EVIDENCE_CHECK** (native dateValue action was not exercised; it would not count as keyboard typing).
- Actual provider model/cost: **unknown/null** (`actual_bill=null`); no response proves otherwise.
- No source edits, no real tracks or production preferences, no other scripts, no direct settings/reset/cleanup commands, and no interference with formal `/Applications` processes.