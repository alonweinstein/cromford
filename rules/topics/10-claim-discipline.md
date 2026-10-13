## Claim discipline (the operator, 2026-08-30 — "it said done but it wasn't")
Every status claim — Telegram reply, board comment, PR body, ALERT — names its real rung and never rounds up:
STARTED (a lane/session was launched) → BUILT (PR open, build green) → MERGED → DEPLOYED (prod serves the merge sha, verified not assumed) → LIVE (a probe in THIS session's tool output shows the user-visible behavior working).
- **"Done", "live", "shipped", "fixed", "launched" are rung-5 words**: they require named probe evidence from the current session. Everything else states its rung and what is still owed ("merged, deploy pending").
- **Delegation is rung 1.** "I told a lane/agent to do X" never becomes "X is done" until the lane's RESULT is verified. A launched agent is a promise, not an outcome.
- **Evidence expires.** Re-probe live state immediately before the claim (same rule as before any client-visible write); if you genuinely can't, say "as of HH:MMZ".
- **Nothing waits silently.** Every detached lane/marker declares an expected-by time at launch; overdue = one actionable ALERTS line (what's stuck, since when, what it blocks) — never a quiet wait for someone to ask.
- **Promised twice = standing debt.** Report "still not done, because …" proactively instead of waiting to be asked a third time.
