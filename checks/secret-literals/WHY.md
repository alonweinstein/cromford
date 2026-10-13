# secret-literals

- **Family key:** `4d8b31f48fbd`
- **30-day count when promoted:** 5
- **Projects:** pool-project-4, pool-project-1, pool-project-3, pool-project-2
- **Ruled by the miner:** 2026-08-26 (`state/rule-mining/20260826/14-findings-4d8b31f48fbd.md`)
- **Promoted to `checks/`:** 2026-08-29

## The findings it was mined from

```
2026-08-26 [pool-project-4]       ticket=TK-1055 lens=security :: Secrets / tokens in code or logs
2026-08-26 [pool-project-1]   ticket=TK-26   lens=security :: Secrets / tokens in code or logs
2026-08-26 [pool-project-2] ticket=TK-139  lens=security :: Secrets / tokens in code or logs
```

## The objectivity test

- **Measurable observation:** an added line carrying a credential-shaped literal
  (`sk-ant-apiNN-`, `AKIA…`, `ghp_`/`gho_`/`ghs_`/`ghu_`/`ghr_`, `github_pat_`,
  `xoxb-`/`xoxp-`, a PEM `PRIVATE KEY` header, a `eyJhbGciOi` JWT header), OR a
  `console.*` / `logger.*` / `echo` call on the same line as an identifier
  containing SECRET / TOKEN / PASSWORD / API_KEY / PRIVATE_KEY / CREDENTIAL.
- **Named tool:** `checks/secret-literals/check.sh`.
- **Explicit threshold:** one or more such lines. For the `gh[pousr]_` prefixes the
  threshold is also a LENGTH: the prefix plus at least 20 alphanumerics (24 in
  total), which is the bound `bin/transcript-scrub.sh`, `tests/evals/*` and
  `tests/skills-sync-test.sh` already redact on. A real PAT or installation token
  is 40. A run under 24, or one of 24-39 being defined/called/piped as a symbol,
  is an identifier and is not a hit — see BH-1124 below. The symbol rule stops
  at 40: a run of real token length is a hit whatever punctuation surrounds it.

Reading `process.env.CRON_SECRET` is fine and is not flagged. Printing it is.

## Known false positives

- A log line whose message text merely mentions the word "token"
  (`console.log("token refreshed")`). Cheap to read, cheap to dismiss.
- A bracketed log LABEL carrying a secret word — `console.error("[TOKEN-ALLOWANCE-RESET] pool refill failed:", message)`.
  Fixed 2026-08-30 (project-3#274 sat parked on exactly this): `[A-Z0-9_-]+` in
  square brackets is stripped before the secret-NAMED test. The
  credential-SHAPED test still reads the raw line, so a real key inside
  brackets is still caught.
- The `bin/lib/gh-shim/` namespace. Every function in the REST shim is named
  `ghs_something` — `ghs_author`, `ghs_paginate`, `ghs_passthru`, `ghs_fields_ok`,
  `ghs_slug` — and the old pattern asked for six alphanumerics after the prefix,
  which `author` satisfies. PR #882 answered 38 hits when BH-1124 was filed and 42
  by the time it was fixed, all of them function names, and the merge conductor
  held the PR in BLOCKED_HUMAN for 617 minutes on them. Any PR touching a shim
  file re-tripped it. Fixed 2026-09-20 (BH-1124): the GitHub branch now requires a
  24-character run and skips a 24-39 character run followed by `_`, `(`, `=` or
  `$`, or introduced by `def `, `function ` or a `|`. Those shape exclusions
  arbitrate that band only — at 40 characters the run fires unconditionally, so
  a real token in a markdown table cell (`| ghs_… |`) or written `TOKEN=ghs_…=`
  is not silenced by its punctuation. `checks/secret-literals/fixtures/clean.diff`
  carries three real shim lines and the violation fixture carries a 40-char `ghs_`
  literal, so both directions stay proven.
- A test double or a documented example key living outside a test path.

## What it deliberately does NOT do

It never redacts, rewrites or scrubs. A credential this finds is already in a
commit; rotating it is a human decision with a vendor console on the other end,
and a script that quietly edited the line would destroy the evidence a human
needs to decide whether it ever reached a remote.
