These fixtures are entirely offline and contain no credentials or account data.

`mock_cli.py` emits Claude-compatible stream JSON. Choose a scenario with
`MOCK_SCENARIO`; it tolerates unrelated CLI options. `MOCK_DELAY` controls the
pause after a streamed long tool input/result. Token-like values are public
synthetic redaction canaries, never valid credentials.

`legacy_ledger.md` deliberately has inconsistent cumulative totals and an unknown
cost so import/recalculation tests cannot trust the final cumulative column.
