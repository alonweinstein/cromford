# Board state (GitHub Issues) — tick at 2026-09-21T10:05:00Z

## gh issue list -R example-org/project-6-runtime --label ai-build --state open --json number,title,labels,updatedAt,comments
```json
[
  {"number":7041,"title":"Spec loader reads warehouse specs from a directory","labels":[{"name":"ai-build"}],"updatedAt":"2026-09-21T10:01:00Z","comments":2},
  {"number":7036,"title":"Repo skeleton: CLAUDE.md, test runner, CI workflow","labels":[{"name":"ai-build"}],"updatedAt":"2026-09-17T12:00:00Z","comments":3}
]
```

## gh issue view 7041 -R example-org/project-6-runtime --json title,body,comments,labels,state
```json
{
  "title": "Spec loader reads warehouse specs from a directory",
  "state": "OPEN",
  "labels": [{"name": "ai-build"}],
  "body": "## Scope\nA loader that reads every `*.spec.yaml` under a directory into typed spec objects, and rejects a file that is missing `id` or `version` with an error naming the file.\n\n## Acceptance tests\n- `tests/spec-loader.test.ts`: two valid specs in a temp dir load as two objects.\n- `tests/spec-loader.test.ts`: a spec without `version` fails with the file name in the message.\n",
  "comments": [
    {"author": {"login": "operator"}, "createdAt": "2026-09-19T08:00:00Z",
     "body": "Filed from the orchestrator outline. The skeleton issue already merged, so tests and CI exist now."},
    {"author": {"login": "operator"}, "createdAt": "2026-09-21T10:01:00Z",
     "body": "YAML only for now, no JSON specs. Go ahead."}
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-6
2 (box slots 2, 0 running, no wip limit)
$ cat /root/harness/state/project-6.json
{"7036":{"updatedAt":"2026-09-17T12:00:00Z","state":"OPEN"},"7041":{"updatedAt":"2026-09-19T08:00:00Z","state":"OPEN"}}
$ ls /root/harness/builds/project-6-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-6-runtime --state all --search "TK-7041"
(no results)
$ git ls-remote --heads origin "*TK-7041*"
(no results)
```
