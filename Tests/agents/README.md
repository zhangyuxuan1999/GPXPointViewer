# Agent runner offline regressions

Run from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/agents -p 'test_*.py' -v
```

The tests use only local standard-library fixtures. `mock_cli.py` replaces Claude
CLI; `mock_sdk/claude_agent_sdk.py` replaces the SDK transport. SDK cases use a
public noncredential canary and a fake `security` executable so they cannot read
the actual keychain. No test starts the app or requests a public routing service.

Each integration case runs in an independent `/private/tmp/gpxpv-runner-tests-*`
workspace. Complete command, stdout, stderr, structured result, event stream,
snapshot, and synthetic Git evidence are copied into
`Tools/agents/records/2026-10-28-remediation/runner-tests/evidence/`. This avoids
writing synthetic runs to the project's real agent index. The parent task's
`journal.jsonl` records commands and evidence references.

`test_legacy_repros.py` intentionally proves five defects in the preserved
pre-remediation sources under that task's `inputs/` directory. Those evidence
tests do not assert that the repaired runner should retain the old behavior.

Run state and independent verification are tested separately. Provider success
with `verification_status=not_run` does not mean the product test passed. USD
budget tests freeze allocation after unknown cost; bounded DeepSeek attempts
retain unknown costs and can create another explicitly limited run.
