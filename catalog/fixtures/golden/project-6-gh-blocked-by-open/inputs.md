# Board state (GitHub Issues) — tick at 2026-09-21T15:30:00Z

## gh issue list -R example-org/project-6-runtime --label ai-build --state open --json number,title,labels,updatedAt,comments
```json
[
  {"number":7044,"title":"Orchestrator dispatches one agent per spec","labels":[{"name":"ai-build"}],"updatedAt":"2026-09-21T09:00:00Z","comments":4},
  {"number":7045,"title":"Run a spec end to end through the orchestrator","labels":[{"name":"ai-build"}],"updatedAt":"2026-09-21T15:20:00Z","comments":2}
]
```

## gh issue view 7045 -R example-org/project-6-runtime --json title,body,comments,labels,state
```json
{
  "title": "Run a spec end to end through the orchestrator",
  "state": "OPEN",
  "labels": [{"name": "ai-build"}],
  "body": "## Scope\nA CLI command that loads one spec, hands it to the orchestrator and writes the run record to `runs/<spec-id>.json`.\n\nBlocked-by: #7044\n\n## Acceptance tests\n- `tests/run-spec.test.ts`: running a fixture spec writes a run record with status `done`.\n",
  "comments": [
    {"author": {"login": "operator"}, "createdAt": "2026-09-20T11:00:00Z",
     "body": "This is the first thing a user will actually run."},
    {"author": {"login": "operator"}, "createdAt": "2026-09-21T15:20:00Z",
     "body": "Design is settled: one command, one spec, one run record."}
  ]
}
```

## gh issue view 7044 -R example-org/project-6-runtime --json state,title
```json
{"state": "OPEN", "title": "Orchestrator dispatches one agent per spec"}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-6
2 (box slots 2, 0 running, no wip limit)
$ ls /root/harness/builds/project-6-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-6-runtime --state all --search "TK-7045"
(no results)
$ git ls-remote --heads origin "*TK-7045*"
(no results)
```
