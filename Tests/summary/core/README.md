# Daily/journey production-core probes

These offline probes compile the real `JourneySummary.swift` and unchanged `RegionIndex.swift` with Foundation, CryptoKit and Darwin test support. They do not launch the app or run routing, legacy suites, Release builds or UI tests. The exact statistical contract is [journey-summary-design.md](../../../docs/journey-summary-design.md).

From the repository root, choose a new artifact root that you own:

```sh
python3 Tests/summary/core/run.py --output-root /private/tmp/summary-core-proof
```

The default runs the20 small deterministic/cancellation cases. Scale samples are explicit:

```sh
python3 Tests/summary/core/run.py --output-root /private/tmp/summary-core-proof scale-continuous-million
python3 Tests/summary/core/run.py --output-root /private/tmp/summary-core-proof scale-overlap-million
```

Pass one or more exact case names to run only that scope. A built probe's `--list` lists the names. `--build-only` compiles without cases. Reuse a saved probe through `--binary /absolute/output/summary-probe`; the wrapper refuses reuse when any captured source/test input hash differs. It creates a fresh unique output directory for every invocation and keeps complete command argv, stdout/stderr, actual child exit, source snapshots, before/after SHA-256, fixture hash, compiler version and per-case JSON results. It puts the Swift module cache inside that output directory to respect restricted workspaces.

Cases cover independent equatorial arc truths; source/segment interleaving and overlap; explicit/implicit source selection;300s continuity and1800s journey boundaries; plausible-speed boundary sides; malformed complete topology, columns, coordinate and timestamp diagnostics; valid-zero/unavailable distinction; UTC midnight, Berlin23/25hour DST days and timezone invariance; no fabricated empty days; synthetic/retimed/segment-qualified provenance; observed/estimated interval precedence and moving conflicts; median5/deadband, exact80% elevation coverage, missing/synthetic/gap chain breaks and midnight5m/5m splitting; nested offline region-parent evidence and unavailable/unassigned states; duration/edge transport evidence thresholds and unconfirmed candidate sets; real production cancellation; and two million-point samples.

The input fingerprint covers numeric columns (including NaN bit patterns), file selection, topology, IDs, timezone and sorted provenance keys. Generated region geometry is three explicitly nested squares; its binary bytes are captured and hashed. Expected distances use `6_371_000 * angle`; expected intervals and platform elevation steps are manually derived, rather than copying the production engine.

`processPeakRSSBytes` comes from Darwin `getrusage(RUSAGE_SELF)` for the probe process, including input arrays/test support. Each scale case is run in its own process. `buildAndInputHashWallSeconds` includes hashing the generated input plus the engine call. `cancellationWallSeconds` includes hashing and work before the callback signals at invocation1000; it does not measure external signal-to-throw latency. These standalone measurements do not establish main-thread responsiveness, UI frame rate, all possible input performance or a release verdict.

The2026-10-30 implementation evidence is preserved under the engine run at `Tools/agents/records/2026-10-30-journey-summary/native/20261030T042612.157547Z_journey-summary-engine_262efea5/`. The original19 small cases passed before a review-driven cancellation checkpoint; only the three affected cancellation/overlap cases were rerun. A new twentieth small case proves midnight elevation proportions. Both scale cases passed once. Original compile failures and the first `/usr/bin/time -l` sandbox failure remain retained; final measurement uses the actual probe exit and Darwin RSS without that denied sysctl call.
