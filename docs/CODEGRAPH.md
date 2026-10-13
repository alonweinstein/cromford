# CodeGraph on the fleet

Installed 2026-07-29 (replacing Understand-Anything, which built its graph with
agent tokens; CodeGraph indexes locally with a Rust kernel for free).

What each box has:
- `codegraph` CLI at ~/.local/bin (installed by bootstrap-machine.sh)
- MCP server wired into Claude Code globally (`codegraph install -t claude -l global -y`)
- Telemetry OFF permanently (`codegraph telemetry off` + DO_NOT_TRACK) — fleet boxes touch client code
- Every repo under /root/repos indexed (`codegraph init`, safe to re-run)

How the pipeline uses it:
- run-build.sh runs `codegraph sync` (incremental, cheap) before the plan stage so the graph reflects HEAD
- The PLAN prompt derives "files to touch" and regression-risk lists from `codegraph explore` / `codegraph query`
  evidence (callers, dependents, call paths) instead of grep guesses — this feeds the file-overlap build
  serialization and the XL-decomposer, so accuracy here buys real scheduling wins
- The EXECUTE prompt prefers `codegraph explore` over grep/find for locating code
- Project CLAUDE.mds carry a matching CodeGraph section; skip everything if a repo has no `.codegraph/` dir

Useful commands: `codegraph explore "<question>"`, `codegraph query <search>`,
`codegraph affected` (which tests a diff touches), `codegraph status`, `codegraph sync`.
