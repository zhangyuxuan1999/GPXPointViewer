# Release r2: missing final build evidence

Started after required 68 build inputs and five delivery documents were confirmed local at 2026-10-29T22:54:28Z. User twice explicitly requested continued waiting while iCloud downloaded. Nine frozen reviewed/tested product inputs match expected SHA-256 in recovered-source-comparison.json. Remaining receipt files continue downloading; final attribution will compare those when available.

Reason: previous build Builds/20261029T210753Z_release_8f33bba8 never reached compilation and blocked in NSFileCoordinator. Its owned xcodebuild child was interrupted (exit130 / child -15 / cleanup complete); preserve the old attempt. Product changes require one successful attributed Release. Use the separately reviewed process-only --no-icloud-coordination option. No global preference changes, installation, application launch, or repeated passing tests.

Command: python3 Tools/build_release.py --arch arm64 --no-sign --no-icloud-coordination --timeout 1200

Capture through coordinator/capture.py; retain stdout/stderr, argv, build.log, source before/after, and complete bundle manifest. After success inspect real ContentView/GPXWriter stringsdata for the two new localization keys and finalize documents. A failed build is not acceptance.
