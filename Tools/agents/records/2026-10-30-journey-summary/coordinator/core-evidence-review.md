# Root core acceptance — 2026-10-30
Accepted author and independent Sol review evidence; no root tests/build/benchmarks rerun.
Author output, final-evidence and reviewer full output read through archived capture commands. Final core SHA d4b339e61278e765536e3d87aceb22677a00cd11380c3933cd9d32777e0c7da3 matches directed tests and reviewer snapshots.
22 unique cases' assertions passed (19 original + new cross-midnight altitude case + two first million samples). Original time-wrapper exit1 is retained, not a clean process pass. Final source only adds the specific overlap grouped-loop cancellation checkpoint after first19; affected3 cases passed on final source, other16 inherited. Review found no remaining concrete core issue.
Million samples use nil region index, one/two continuous segments and flat elevation. 0.234/0.223s includes input hashing;47.2/55.2MB are process peak RSS. Not arbitrary real-track or UI performance proof.
No app/Store/Release/pixels acceptance is implied. Those scopes remain separate.
Root manual-override correction: design guarantees same-source timezone retention, not persistence across changing selected source. Current UI clears source change; no product change or rerun is requested for root's earlier paraphrase. Final docs must match exact contract.
