# Signed artifact path documentation — final report

## Files changed

### `README.md`
- **「命令行 Release 构建与 UI 测试归档」**:
  - Replaced generic `/ABS/Builds/RUN/archive/GPXPointViewer.app` examples with `/ABS/APP_FROM_BUILD/GPXPointViewer.app`.
  - Updated manifest example to `/ABS/APP_FROM_BUILD/build-manifest.json`.
  - Reworked the build-output paragraph to state that `build_release.py` prints the actual `app`, `manifest`, `durable_zip`, and `durable_manifest` paths; normal builds keep the runnable signed app plus adjacent `build-manifest.json` in a unique local staging directory outside iCloud; the project `Builds/<RUN>/archive/` keeps the durable ZIP, manifest, proof, and paths records.
  - Added the warning to use printed app/manifest paths for UI tests, validation, and installation rather than assuming `archive/GPXPointViewer.app` exists, with a link to `docs/local-install-signing.md`.
  - Updated the authorized install example to the printed-app placeholder.

### `Tests/README.md`
Updated the same artifact-path contract in:
- **0. 速查** — build description and `GPXPV_APP` example.
- **2.2 构建 Release 并归档** — build comments, `archive_build.py` path, printed-path/durable-ZIP/project-records explanation, `GPXPV_APP` / `GPXPV_BUILD_MANIFEST` examples, and installability validation path.
- **3.2 跑全套** — `GPXPV_APP` and optional `GPXPV_BUILD_MANIFEST` examples.
- **7. 改完代码之后的推荐顺序** — build/validate/UI/install examples and the installation paragraph now use the printed app placeholder; removed the stale `Builds/.../archive/GPXPointViewer.app` installation assumption.

All generic `/ABS/Builds/RUN/archive/...` app and manifest examples were replaced with `/ABS/APP_FROM_BUILD/...` placeholders.

## Preserved unchanged
- Historical evidence paths `/ABS/OLD/GPXPointViewer.app` and `Builds/TIME_historical_UUID/`.
- Existing statement that actual date-navigation build/UI/cross-process results are not claimed as passed.
- Statistical rules, 25-suite-script count, 114-item historical synth status, 2026-10-24 log references, and other passing counts.
- No product code, tests, scripts, or signing documentation changed.

## Verification and limits
- Inspected and edited only `README.md` and `Tests/README.md` plus this run's `progress.md`.
- Grep confirmed no remaining `/ABS/Builds/RUN/archive` or `/ABS/build-manifest.json` generic examples; remaining `archive/GPXPointViewer.app` text is intentional “do not assume this path exists” guidance.
- **Not executed:** Bash commands, builds, compiles, tests, app/UI launches, network calls, or validation runs.
- `docs/local-install-signing.md` was not read; the supplied contract was used as authoritative.
- Actual model/cost: **unknown / null**.