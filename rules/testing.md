---
description: Testing standards and behavioral instructions — tests are required for all implementation work, not optional
globs:
  - "**/*"
---

# Testing Rules

> Invoke `/workflow` for Phase 5 (implementation) with gated testing enforcement — tests must pass before proceeding.

## What is actually enforced (LAB-1369)

This section exists because everything below it was **aspirational and stated as fact**
until 2026-08-21. No test had ever run in CI, and the local pre-commit gate was a
structural no-op that exited 0 on every commit. Read the distinction carefully.

**Enforced, automatically:**

| Gate | Where | Effect |
|---|---|---|
| Every discovered suite runs | `.github/workflows/tests.yml`, on every PR | A failing suite fails the build unless it is in `ci/test-allowlist.json` with a reason and a follow-up issue |
| The suite owning your staged files runs | `.claude/hooks/pre-commit-tests.sh` | Blocks the commit on real test failures |

Suites are **discovered**, not listed — `internal/scripts/discover-test-suites.sh` finds
any component containing test files. Adding a component with tests needs no config change.

**Deliberately not enforced:**

- **The 90% coverage target below is a goal, not a gate.** Nothing measures or blocks on it.
- `tests/integration/` is **excluded from CI** — those suites need live postgres-memory,
  ollama and mlflow, which a hosted runner cannot reach. Putting a test there is how you
  declare it needs live services.
- The pre-commit hook **skips loudly** (never silently passes) when a component cannot be
  collected locally, which usually means its dependencies are not installed on this
  machine. CI runs the same suite with a clean install.

**There is deliberately no suite or test count in this file.** Run
`bash internal/scripts/discover-test-suites.sh` for the current suite list; the CI run
reports the test totals. Any number written here is stale the day a component grows a test
directory — which is the whole point of the sentence directly above it. This line used to
read *"8 suites, 264 tests passing"*, a figure measured at #1369's close that had drifted
badly by the time anyone reread it, contradicting its own paragraph (#1537).

`internal/agent-runtime` is allowlisted pending #1394.

## Behavioral Instructions (always active)

These apply to all implementation work, not just test files:

- **Tests are required, not optional.** Before marking work complete, verify:
  - Unit tests cover the changed business logic (**goal**: 90%+ on new code — not measured or gated; see above)
  - Integration tests exist for any new external service interactions
  - Edge cases and error paths are tested

- **Test-first when possible:**
  - For bug fixes, write a failing test that reproduces the bug before fixing it
  - For new features, write test scenarios during the planning phase

- **Testing is part of acceptance criteria:** Every ticket's acceptance criteria must include at least one test-based criterion (`Tests pass: <command>`).

- **On `/complete-task`:** The test suite must pass as a hard gate. Test coverage on changed files must not decrease.

## Standards for Test Code

When writing or modifying tests:

1. **Follow AAA pattern** — Arrange, Act, Assert in every test
2. **One concern per test** — each test should verify a single behavior
3. **Use descriptive names** — `test_user_registration_fails_with_invalid_email` not `test_reg`
4. **Mock external dependencies** — APIs, databases, file systems should be mocked in unit tests
5. **Use fixtures for shared setup** — don't repeat test data construction
6. **Test edge cases** — empty inputs, boundary values, error paths, concurrent access
7. **Keep unit tests fast** — each should complete in <1 second
8. **No real credentials in tests** — use clearly fake test data
9. **Aim for 90%+ coverage on business logic** — focus on critical paths, not getters/setters
10. **Integration tests hit real services** — use test databases or containers, not mocks
