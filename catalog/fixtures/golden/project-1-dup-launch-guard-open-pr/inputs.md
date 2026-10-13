# Board state — tick at 2026-09-21T13:15:00Z

## GET /api/board/boards
```json
[{"id":"brd_m7a2","key":"TK","name":"Product Board"}]
```

## GET /api/board/tickets/7101 (via board-fetch.sh --since-file)
```json
{
  "id": 7101,
  "key": "TK-7101",
  "title": "CSV export of the inventory table",
  "description": "We need to hand the inventory list to the auditors every quarter. An export button would save a day.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Rhea Castell (client team, ops lead)",
  "comments": [
    {
      "id": 71011,
      "authorId": "u_rhea",
      "author": "Rhea Castell",
      "createdAt": "2026-09-19T10:00:00Z",
      "body": "We need to hand the inventory list to the auditors every quarter. An export button would save a day."
    },
    {
      "id": 71012,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-19T10:01:00Z",
      "body": "[AI Triage] Should the export include retired items, or only what's in stock today?"
    },
    {
      "id": 71013,
      "authorId": "u_rhea",
      "author": "Rhea Castell",
      "createdAt": "2026-09-21T13:09:00Z",
      "body": "Only what's in stock today. Same columns as the table."
    }
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-1
2 (box slots 2, 0 running, no wip limit)
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ ls /root/harness/builds/project-1-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-1 --state all --search "TK-7101"
#1733  TK-7101 csv export of the inventory table  OPEN  partner-dev  2026-09-21T07:02:00Z
$ git ls-remote --heads origin "*TK-7101*"
7c1f92a3  refs/heads/TK-7101-csv
$ gh pr view 1733 -R example-org/project-1 --json files,author
{"author":{"login":"partner-dev"},"files":["src/app/inventory/page.tsx","src/app/api/inventory/export/route.ts","tests/inventory/export.test.ts"]}
$ curl -s -X POST .../v1/acquire -d '{"key":"project-1:TK-7101","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
