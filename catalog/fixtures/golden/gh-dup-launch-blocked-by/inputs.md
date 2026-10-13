# Board state (GitHub Issues) — tick at 2026-08-24T15:30:00Z

## gh issue list --label ai-build --state open
```json
[
  {"number":60,"title":"Correspondent identity resolution service","labels":[{"name":"ai-build"}],"updatedAt":"2026-08-24T09:00:00Z","comments":4},
  {"number":61,"title":"Correspondent detail page","labels":[{"name":"ai-build"}],"updatedAt":"2026-08-24T15:20:00Z","comments":2},
  {"number":62,"title":"Export button on the correspondent list","labels":[{"name":"ai-build"}],"updatedAt":"2026-08-24T15:25:00Z","comments":1}
]
```

## gh issue view 61 --json title,body,comments,labels,state
```json
{
  "title": "Correspondent detail page",
  "state": "OPEN",
  "labels": [{"name": "ai-build"}],
  "body": "## Scope\nA page per correspondent: their messages over time, the accounts they appear on, and the recurrence score.\n\nBlocked-by: #60\n\n## Acceptance tests\n- `tests/correspondents/detail.test.tsx`: renders the recurrence score for a seeded correspondent.\n",
  "comments": [
    {"author": {"login": "operator"}, "createdAt": "2026-08-23T11:00:00Z",
     "body": "This is the page the whole compliance story hangs off."},
    {"author": {"login": "operator"}, "createdAt": "2026-08-24T15:20:00Z",
     "body": "Design is settled — same table layout as the accounts list, sortable headers."}
  ]
}
```

## gh issue view 60 --json state,title
```json
{"state": "OPEN", "title": "Correspondent identity resolution service"}
```

## gh issue view 62 --json title,body,comments,labels,state
```json
{
  "title": "Export button on the correspondent list",
  "state": "OPEN",
  "labels": [{"name": "ai-build"}],
  "body": "## Scope\nAdd a CSV export button to the correspondent list, same columns as the table.\n\n## Acceptance tests\n- `tests/export/correspondents.test.ts`: the export contains one row per visible correspondent.\n",
  "comments": [
    {"author": {"login": "operator"}, "createdAt": "2026-08-24T15:25:00Z",
     "body": "Small one, go ahead."}
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-5
2 (0 build(s) running, 2 box slot(s))
$ ls /root/harness/builds/project-5-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-5 --state all --search "TK-61"
(no results)
$ gh pr list -R example-org/project-5 --state all --search "TK-62"
#88  TK-62 export button on the correspondent list  OPEN  operator  2026-08-24T14:02:00Z
$ git ls-remote --heads origin "*TK-62*"
b41c07e9  refs/heads/TK-62-correspondent-export
```
