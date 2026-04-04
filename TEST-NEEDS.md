# Test Requirements — Session Sentinel

## CRG Grade: C — ACHIEVED 2026-04-04

This is a container/infrastructure repo (no compiled source code). CRG Grade C
for this category means structural validation tests covering all test categories.

| Category | File | Tests | Status |
|----------|------|-------|--------|
| Unit | `tests/validate.test.ts` | 9 file/dir existence checks | PASS |
| Smoke | `tests/validate.test.ts` | 3 non-empty content checks | PASS |
| P2P / property | `tests/validate.test.ts` | all TOML files parse (7 files) | PASS |
| E2E | `tests/validate.test.ts` | 2 full validation chains | PASS |
| Contract | `tests/validate.test.ts` | 3 required-field checks | PASS |
| Aspect | `tests/validate.test.ts` | 3 secret/placeholder checks | PASS |
| Benchmark | `tests/validate.test.ts` | TOML scan timing baseline | PASS (6.7ms) |

Total: 22 tests, 0 failures.

## Notes

- `compose.toml` and `compose.example.toml` were using TOML 1.1 multiline inline
  tables. Fixed to standard TOML 1.0 sub-table syntax for broad tooling compatibility.
- `deno.json` added with `test` task.

## Running Tests

```bash
deno task test
# or directly:
deno test --allow-read tests/
```
