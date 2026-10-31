# Independent core review

**Decision:** core review complete; no outstanding actionable core defect found in final engine SHA `d4b339e61278e765536e3d87aceb22677a00cd11380c3933cd9d32777e0c7da3`. Provider execution succeeded; independent acceptance remains pending for the coordinator. This is core-only, not app/Store/UI/release acceptance.

Requested review model/effort: GPT-6.1 Sol / ultra. Native tools do not expose independent server model, token or cost verification; observed values remain null. Reviewer performed static reads, snapshots, diffs and evidence assessment, with **no tests, builds, benchmarks, app launches, network or product writes**.

## Findings

### CORE-R1 — P2, fixed: missing grouped-event cancellation checkpoint

- Initial source SHA: `af3a0fa9e6b463e84ba1e492eea395c402376cfdfdb79607bfdac2fd44cb82b0`, `JourneySummary.swift:602-605`; the same omission persisted in tested SHA `1f08b2c947ef43dac1682a39a04968304b05f6c5ed6c7a4cb50053492541e835`.
- Trigger: more than4096 source-span endpoints sharing a timestamp. The inner sweep grouping loop consumed the entire equal-time group without checking cancellation, violating the specified maximum4096 processing cadence. No measured responsiveness failure or numerical error was claimed.
- Expected: inner event reduction observes the same bounded checkpoint cadence. Smallest fix: check cancellation inside the grouped loop every4096 events.
- Author applied precisely that check at final source line607. Static diff is saved at `artifacts/capture/commands/20261030T045751_fixed-engine-diff_d5805a53/stdout.log`.
- Author documented the retest reason in its `artifacts/retest-03-measurement-cancellation.md` before directed overlap/cancellation validation. Those3 affected existing cases pass with actual child exit0 and stable source SHA in `20261030T045714.829398Z_657f12d0`. The directed cases are regression evidence; they do not themselves construct a >4096-equal-events cancellation trigger. The direct source fix resolves the exact static omission without requiring a redundant scale rerun.

No additional confirmed numerical, topology, provenance, calendar or interval-union defect was found.

### Test/evidence clarifications, resolved

- The original elevation-midnight case asserted conservation but its triggering edge ended exactly at midnight. Requested a first focused case whose trigger edge spans midnight. Author added `elevation-midnight-proportions`: independent10m step across [-15,+15]seconds yields5m each day,10m journey; passed at `20261030T045816.459358Z_666ea520`, actual child exit0, final engine SHA unchanged.
- `cancellationWallSeconds` measures the whole synchronous call, including input hashing and work before callback1000 requests cancellation. It is **not external signal-to-throw latency**. Author acknowledged this limitation; review does not advertise a signal-response guarantee.

## Scope inspected

Read project rules, runner/capture rules, code-review skill, README/Tests README relevant entry points, accepted Astra design SHA `5737bce7ad93dad939ec319c99c86f1196ca4b9e8e138d4351f84591094436c0`, the complete new engine, production topology representation, RegionIndex parent/Assigner contract, deterministic test main, fixture generator and runner.

Checked selected-source membership, complete permutation/segment validation, strict-positive finite time edges and continuity/speed boundaries; source-qualified bit-pattern provenance and synthetic precedence; Gregorian natural days/DST, half-open midnight ownership and contribution conservation; independent interval unions O/E/M and overlap spans; padded median5/deadband chain breaks, coverage and midnight elevation allocation; recorded/synthetic geographic ancestors, unassigned/unavailable state; conservative transport eligibility/weighting; fixed-size elevation window, interval compaction, cancellation checkpoints and sorting boundaries.

Final inspected/validated source identities:

| Input | SHA256 |
|---|---|
| `GPXPointViewer/JourneySummary.swift` | `d4b339e61278e765536e3d87aceb22677a00cd11380c3933cd9d32777e0c7da3` |
| `GPXPointViewer/RegionIndex.swift` | `341c320e0eccc08ae2cc1a8731e1d63d0be10a484cf8ab5fad0fd6d5d34af263` |
| `Tests/summary/core/main.swift` | `2e69c8d6212983855b0f76f0486662fdaad433bf53945f52a5ee36bd370e688f` |
| `Tests/summary/core/run.py` | `f3c3e5ea06f8a27442c4dbf758ae975866a726894a5d2d04cbab605b616b1347` |
| `Tests/summary/core/fixtures.py` | `b3647cb7b7856439e36622926d7d471a30ccc4e7e0000152d544c1b342ec44e4` |

RegionIndex sentinel remained unchanged from first to final inspection. All source versions reviewed are retained under `artifacts/initial-source`, timestamped `artifacts/source-*`, and inherited validation `source/` directories. A snapshot-label correction is explicitly documented in `artifacts/snapshot-correction.md`; original full capture logs were retained and restored the first engine SHA exactly.

## Inherited execution evidence; no reviewer reruns

Author run: `../20261030T042612.157547Z_journey-summary-engine_262efea5/`. Exact raw logs, manifests and source snapshots are copied with SHA manifests under this run's `artifacts/inherited-evidence/`.

| Author validation directory | Evidence and acceptance |
|---|---|
| `20261030T045557.337636Z_fe6c0539` |19 original distinct small/cancellation cases report passed on engine `1f08b2c9`; compile exit0. `/usr/bin/time -l` wrapper exits1 with sandbox-denied `sysctl kern.clockrate` **after** named passing outputs. Retain the wrapper failure; do not call this a clean full-process pass. Original source/expectations are preserved. |
| `20261030T045714.829398Z_657f12d0` |3 directed affected cases (`topology-interleaving`, `interval-precedence`, `cancellation`) pass, compile0, actual child0 on final `d4b339e6`; source hashes stable before/after. The other16 original cases are inherited, not repeated or represented as newly run. |
| `20261030T045816.459358Z_666ea520` |New midnight proportional elevation case passes, compile0, child0; final engine/test hashes stable. |
| `20261030T045849.983361Z_23d63685` |First continuous1,000,000-point case passes, child0;12day rows, one journey;0.233806014s builder+input-hash wall,0.257355166s process wall,47,202,304byte process peak RSS. Input SHA `40c94367504a4921ad00bc230abea657a3a177d78fc33ef2a3f6cc2ecfdd2193`. |
| `20261030T045858.218130Z_bac52d16` |First overlapping1,000,000-point/two-source-segment case passes, child0;0.223127007s builder+input-hash wall,0.269846125s process wall,55,246,848byte process peak RSS. Input SHA `a1dda7abd79c1a72fb8e4e6199868ce03f445e4690789e27b30391e53b238eb1`. |

22 distinct named cases have passing assertions across retained evidence: original19, one added elevation allocation case, two first scale cases. The3 directed reruns are not added to the unique count. Final scale binary reuses the exact manifest-checked binary built for the new elevation case. Final validation manifests match before/after. Peak RSS is Darwin `getrusage(RUSAGE_SELF)` for the whole probe process, not incremental engine allocation; builder wall includes input SHA calculation. Million fixtures use `regionIndex:nil`, one/two long segments and flat elevation; measurements do not establish worst-case fragmented/real-world geography performance, UI responsiveness or arbitrary-device timing.

Remaining scope limits: no app Release build, Store publication/cancellation ownership, UI/localization/pixels, real-track provenance adapter or network verification performed by this reviewer. Coordinator handles those separately. No release conclusion is made.

## Records

Exact ordinary commands/full stdout/stderr/real exits: `artifacts/capture/`. All multiline scripts were saved before invocation. The two bootstrap reads and their preserved bytes are documented in `artifacts/bootstrap-transcript.md`. Finding/follow-up messages are saved verbatim in `artifacts/messages/`; no credentials or internal chain of thought were recorded. Final live source hashes were read once after all inherited scale results, with no drift from final evidence.
