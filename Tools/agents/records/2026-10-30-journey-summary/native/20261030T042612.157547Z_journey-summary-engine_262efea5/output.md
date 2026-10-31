# Pure daily/journey engine — completed, acceptance pending

Implemented `GPXPointViewer/JourneySummary.swift` with the exact shared design types and Builder signature. It validates equal-length columns, complete unique topology and compact path permutation; scans only same-source/same-segment neighbors; produces immutable day/journey rows with Gregorian/IANA calendar boundaries, source-qualified provenance, independent spherical distance, observed/estimated/moving interval unions, uncovered time and source-span overlap; streams centered median5/deadband elevation with chain breaks and edge coverage; assigns offline parent region IDs; and returns only unconfirmed speed candidate sets. Cancellation throws and does not publish a partial report. The type skeleton was shared with B before algorithm implementation.

Added only `Tests/summary/core/{main.swift,run.py,fixtures.py,README.md}`. The probes compile production core and unchanged production RegionIndex; each named case has deterministic input hashes, complete compile/command output, and immutable input-source snapshots. No existing expectations, app files outside ownership, RegionIndex, app/window, Release build, legacy suite, network, formal app lifecycle or preferences were changed/executed by A.

Evidence: [final-evidence.json](artifacts/final-evidence.json) contains final owned-file hashes, all executions, per-case results and source relationships. **22 unique cases passed** across retained evidence:19 original small/cancellation cases,1 new midnight-proportional case, and2 million-point samples. The final core differs from the original19-case core only by a review-driven cancellation checkpoint inside equal-time overlap event groups; the three affected cancellation/overlap cases passed on the final core without repeating the other16 cases.

Raw evidence directories under `artifacts/validation/`:

- `20261030T045504.713551Z_ee4ce093`: initial compile exited1 because default module cache was sandbox-denied; no cases ran.
- `20261030T045519.983150Z_0e40dfaf`: compiler typechecker expression budget failure; no cases ran. Split map/sort into explicitly typed materialization loops.
- `20261030T045557.337636Z_fe6c0539`: compile0 and all19 case JSON results passed; outer `/usr/bin/time -l` exited1 because sandbox denied sysctl. Original runner status and stderr remain retained. It is not represented as a clean wrapper exit.
- `20261030T045714.829398Z_657f12d0`: final-core narrow topology/interval/cancellation retest3/3 passed; direct child0. Measurement switched to probe `getrusage(RUSAGE_SELF)` and Python wall time.
- `20261030T045816.459358Z_666ea520`: final-source compile0 and new exact midnight altitude5m/5m case passed; child0.
- `20261030T045849.983361Z_23d63685`: continuous1,000,000points passed once; build+input-hash0.233806seconds; process peak RSS47,202,304bytes; child wall0.257355seconds; inputSHA `40c94367504a4921ad00bc230abea657a3a177d78fc33ef2a3f6cc2ecfdd2193`.
- `20261030T045858.218130Z_bac52d16`: two overlapping500,000point segments passed once; build+input-hash0.223127seconds; process peak RSS55,246,848bytes; child wall0.269846seconds; inputSHA `a1dda7abd79c1a72fb8e4e6199868ce03f445e4690789e27b30391e53b238eb1`.

Directed retry reasons were recorded before execution in `artifacts/retest-01-module-cache.md`, `retest-02-typechecker.md`, `retest-03-measurement-cancellation.md` and `validation-supplement-04.md`. No test expectation changed to make a failed numeric assertion pass; there were no failed numeric assertions.

Final core SHA-256: `d4b339e61278e765536e3d87aceb22677a00cd11380c3933cd9d32777e0c7da3`.

Final test-main SHA-256: `2e69c8d6212983855b0f76f0486662fdaad433bf53945f52a5ee36bd370e688f`.

Limitations: timings are standalone engine-process evidence including input hashing/test support, not UI responsiveness, frame-rate or a release verdict. `cancellationWallSeconds` measures full call including hashing/work before callback1000 signals; it does not measure external signal-to-throw latency. Scale evidence is two samples run once, not a broad benchmark. Source provenance outside this editing session remains unavailable by contract. Initial read-only native bootstrap tool calls were partly uncaptured/truncated; exact commands, response metadata, available excerpts and the unrecoverable portions are disclosed in `artifacts/bootstrap-tool-calls.json` and `bootstrap-receipt.json`; subsequent full input recapture is labeled separately.

Requested model/effort: `gpt-6.1-sol` / `ultra`. Server-observed model, tokens and cost are unknown/null. Provider execution succeeded; independent root acceptance remains pending. Root/independent reviewer should use the saved evidence and source snapshots without rerunning passing work absent a concrete new gap or repair.
