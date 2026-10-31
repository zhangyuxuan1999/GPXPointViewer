# Visual-only recovery preparation completed

Only Tests/ui/run_summary_tests.py changed. Product Swift, Xcode project, archive, build manifest, catalogs and docs were not modified. Existing Release and passing zh12 functional checks are inherited, not repeated.

Driver SHA256:

- Before: 432578b91dfa496b14b837d676513957e3ea8c7a3ebcb6ed845c824de5d8d3b5
- After: 6b4098208dc121389783f87d4817e7f1bbf7861cb4acf24f9fc97eb27cc1c04c

## Changes

Added --visual-extras, which requires --visual-only and zh-Hans. It preserves the existing four daily/journey top/lower screenshots and additionally displays/captures actual single-day-main-chip.png and untimed.png. Necessary setup/readiness/filter show-clear only; no functional assertions, overlay/compare or cache tests. Visual runs explicitly record functional_checks_executed=0 and keep results.json empty.

Added a four-second bounded NSWorkspace/AppKit-only preflight. It saves exact argv/stdout/stderr/status in screen-preflight.json and exits before app launch when the frontmost bundle/name is known loginwindow. It does not use System Events, Apple Events to another app, unlock, wake, login or global preference changes. Query failure/timeout is recorded as unknown rather than evidence that the screen is unlocked; root must still review actual pixels.

The existing full functional branch, archive provenance, unique app copy/PID/IO, raw preference restoration and owned-process cleanup remain unchanged. Mode metadata is recorded separately; optional existing fwdb functional count is represented accurately.

## Evidence

- Concrete reason saved before edit: artifacts/recovery-reason-before-edit.md, linking original black-pixel review, archive and accepted raw results.
- Before/after driver snapshots: artifacts/driver-before.py.txt and driver-after.py.txt.
- Exact diff: artifacts/driver.diff.
- Static-only result: artifacts/static-result.json. AST parse passed; visual-only branch contains zero check() calls.
- Actual inherited raw results/cleanup: artifacts/inherited-actual-results-and-cleanup.json. zh12/12; en/de0 checks; all preference restores true, owned exits-15.
- Ordinary command parameters/stdout/stderr/exit codes: artifacts/capture.

NO App/UI/build/Store/core tests or live preflight query executed in this preparation task. Pixel verdict remains pending; black screenshots are missing evidence, not a demonstrated product defect.

## Future screenshot-only commands — root waits for user unlock

Use a NEW recovery wrapper/run, preserving the original first-acceptance wrapper and all old evidence. The old wrapper locks the previous driver hash and runs zh functional checks, so it must not be reused.

~~~sh
GPXPV_APP=/Users/zyx/Documents/GPXPointViewer/Builds/20261030T052611Z_release_25c40b88/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/Users/zyx/Documents/GPXPointViewer/Builds/20261030T052611Z_release_25c40b88/archive/build-manifest.json python3 /Users/zyx/Documents/GPXPointViewer/Tests/ui/run_summary_tests.py --evidence "$GPXPV_AGENT_RUN_DIR/artifacts/visual-recovery/zh-Hans" --language zh-Hans --visual-only --visual-extras
GPXPV_APP=/Users/zyx/Documents/GPXPointViewer/Builds/20261030T052611Z_release_25c40b88/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/Users/zyx/Documents/GPXPointViewer/Builds/20261030T052611Z_release_25c40b88/archive/build-manifest.json python3 /Users/zyx/Documents/GPXPointViewer/Tests/ui/run_summary_tests.py --evidence "$GPXPV_AGENT_RUN_DIR/artifacts/visual-recovery/en" --language en --visual-only
GPXPV_APP=/Users/zyx/Documents/GPXPointViewer/Builds/20261030T052611Z_release_25c40b88/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/Users/zyx/Documents/GPXPointViewer/Builds/20261030T052611Z_release_25c40b88/archive/build-manifest.json python3 /Users/zyx/Documents/GPXPointViewer/Tests/ui/run_summary_tests.py --evidence "$GPXPV_AGENT_RUN_DIR/artifacts/visual-recovery/de" --language de --visual-only
~~~

Each command creates unique evidence children. Expected captures: zh6 plus en4 plus de4; all three run zero functional checks. Known loginwindow stops before any app launch. Root reviews actual content, wrapping, lower controls, main chip and untimed state after successful capture; existence alone is not pixel acceptance.

Requested model/effort gpt-6.1-sol/ultra. Observed model/effort, token counts and cost unknown/null. Provider succeeded, acceptance pending root diff review.
