## 5. Fail closed, per repo

A `gh pr list` that fails, a ledger that cannot be read, a repo no token can
see: each of those means *we cannot name these PRs' owners*, which is a
different sentence from *these PRs have no owner*, and only one of them may
close a pull request. On any of them the sweep records nothing and acts on
nothing **for that repo**, logs why, and carries on with the others.

A repo that NO token can see is an ALERT, never a quiet skip
(`bin/lib/gh-repo-token.sh`): the hub's default PAT 404s on
`example-org/project-5` and `example-org/project-7`, and an empty PR list there reads
exactly like a repo with no open PRs. That is the 2026-09-12 project-5 shape —
six approved PRs invisible for days because a token could not see them and
nothing said so. The sweep resolves each repo through
`gh_repo_use_token`, which falls back to `GH_ADMIN_TOKEN` from
`env/github-admin.env`.

