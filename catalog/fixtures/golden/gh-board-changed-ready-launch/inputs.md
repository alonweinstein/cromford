# Board state (GitHub Issues) — tick at 2026-08-24T10:05:00Z

## gh issue list --label ai-build --state open
```json
[
  {"number":57,"title":"Redact email addresses in the activity export","labels":[{"name":"ai-build"}],"updatedAt":"2026-08-24T10:01:00Z","comments":2},
  {"number":52,"title":"Weekly digest email","labels":[{"name":"ai-build"}],"updatedAt":"2026-08-20T12:00:00Z","comments":3}
]
```

## gh issue view 57 --json title,body,comments,labels,state
```json
{
  "title": "Redact email addresses in the activity export",
  "state": "OPEN",
  "labels": [{"name": "ai-build"}],
  "body": "## Scope\nThe CSV activity export writes correspondent email addresses in clear text. Replace each address with its stable correspondent id.\n\n## Acceptance tests\n- `tests/export/redaction.test.ts`: an export row for a known correspondent contains the id and no `@`.\n- `tests/export/redaction.test.ts`: two exports of the same correspondent produce the same id (recurrence survives redaction).\n\n## QA screens\n- `/exports` — run an export, download it, confirm no addresses.\n",
  "comments": [
    {"author": {"login": "operator"}, "createdAt": "2026-08-22T08:00:00Z",
     "body": "Filed from the compliance pass. The id must be stable across exports or the recurrence analysis breaks."},
    {"author": {"login": "operator"}, "createdAt": "2026-08-24T10:01:00Z",
     "body": "Correspondent ids are already on the row, so this is a substitution, not a new lookup. Go ahead."}
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-5
2 (0 build(s) running, 2 box slot(s))
$ cat /root/harness/state/project-5.json
{"52":{"updatedAt":"2026-08-20T12:00:00Z","state":"OPEN"},"57":{"updatedAt":"2026-08-22T08:00:00Z","state":"OPEN"}}
$ ls /root/harness/builds/project-5-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-5 --state all --search "TK-57"
(no results)
$ git ls-remote --heads origin "*TK-57*"
(no results)
```
