## Token discipline (fleet-wide, 2026-08-22)
- **gh reads: always `--json` with a minimal field list** (or `-q` jq extraction) — never dump default human output or full API objects into context. GitHub measured a 62% token cut in their own agentic workflows from exactly this.
- **Test runs: failures-only reporters.** Where a repo has vitest ≥4.1, `npm test` is pinned to `--reporter=agent`; don't override it back to verbose. Passing-test output is pure context project-2 (a green project-5 unit run: 113KB default vs 359B agent).
- **Don't re-read files you just read or wrote** unless they changed underneath you; don't cat whole files when a targeted read answers the question.
- **Every `gh pr|issue|run|repo` call on a box goes through `bin/gh-rest-shim` (REST only) — see docs/GH-REST.md; exit 75 = rate limited, not absent.** The shim is not on any box's PATH yet; when it lands, a decision path that reads an empty answer as "nothing there" is the #768 outage again.
