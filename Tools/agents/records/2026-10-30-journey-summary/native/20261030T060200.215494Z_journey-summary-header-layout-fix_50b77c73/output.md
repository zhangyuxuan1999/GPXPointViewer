# Minimal header layout fix completed; affected pixels pending root

Only two owned files changed:

- GPXPointViewer/JourneySummaryWindow.swift: the existing segmented day/journey Picker adds labelsHidden() and an explicit accessibilityLabel using the existing localized key 摘要列表. Its visible day/journey choices, binding and180pt width remain unchanged. The redundant translated visual label no longer consumes that width.
- Tests/ui/run_summary_tests.py: new --layout-only requires --visual-only and rejects --visual-extras. It keeps necessary actual-view fixture/report/manual-water setup and captures only daily-top.png plus journey-lower.png per language. The other capture paths retain their prior behavior.

No core/Builder/numerical/SummaryRow/TrackStore/summary-state API or localization key changed. Existing functional/core/Store results are inherited, not rerun.

## Exact source identity

Window before: 8dd746705efe8129e53d13228cd85e936737a45f7726e9b3294e4ffab3010077
Window after: c7fe0873015050d26d3392c8aea62f9301d2ed011cb52743627f629599749a38

Driver before: 6b4098208dc121389783f87d4817e7f1bbf7861cb4acf24f9fc97eb27cc1c04c
Driver after: 0f9381fbda2380b1bb4e1cbef12433b2a5c568c342abb35f9b2802f216fd2ef3

Before hashes match root's frozen inputs. Added/deleted product files: none.

## Evidence and scope

Root's actual unlocked fourteen-image review identified the label wrapping in en daily-top and de daily-top/journey-top. Concrete reason is saved before edit at artifacts/reason-before-edit.md; exact inherited PNG paths are in artifacts/before.json. No old screenshot or failure record was overwritten.

Before/after file snapshots, exact narrow changes.diff, patch and static-result.json are under artifacts. Python AST parse passed. Static traversal with visual_only=true, layout_only=true, visual_extras=false reaches exactly daily-top.png and journey-lower.png and zero check() calls. Unique Swift quoted string literals have no additions. These are static findings, not runtime/layout acceptance.

NO Swift compile/build, App/UI, Store/core/full functional test, live screen-preflight query, preference mutation or install was executed. Preflight/provenance/owned PID/unique IO/preferences cleanup code was not changed.

## Root-owned follow-up

Root reviews the narrow diff and builds one NEW manifest-bound archive for the view modifier. Do not reuse the older source-bound archive. Then use a new hash-locked execution task with the driver hash above and only the following affected pixel scope:

~~~sh
GPXPV_APP=/ABS/new/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/ABS/new/archive/build-manifest.json python3 /Users/zyx/Documents/GPXPointViewer/Tests/ui/run_summary_tests.py --evidence "$GPXPV_AGENT_RUN_DIR/artifacts/layout/zh-Hans" --language zh-Hans --visual-only --layout-only
GPXPV_APP=/ABS/new/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/ABS/new/archive/build-manifest.json python3 /Users/zyx/Documents/GPXPointViewer/Tests/ui/run_summary_tests.py --evidence "$GPXPV_AGENT_RUN_DIR/artifacts/layout/en" --language en --visual-only --layout-only
GPXPV_APP=/ABS/new/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/ABS/new/archive/build-manifest.json python3 /Users/zyx/Documents/GPXPointViewer/Tests/ui/run_summary_tests.py --evidence "$GPXPV_AGENT_RUN_DIR/artifacts/layout/de" --language de --visual-only --layout-only
~~~

Expected new evidence: six PNGs total and zero functional checks. Root checks that the header has no redundant wrapped Summary List label and lower detail/manual controls use the recovered vertical space. Prior main-chip/untimed/other detail pixels and passing twelve functional checks remain inherited.

Requested model/effort gpt-6.1-sol/ultra. Observed serving model/effort, tokens and actual cost unknown/null. Provider succeeded; acceptance pending root source/diff review and later affected pixels.
