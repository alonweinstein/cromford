# Board state — tick at 2026-08-24T13:15:00Z

## GET /api/board/boards
```json
[{"id":"pb-board-1","key":"TK","name":"Product Board"}]
```

## GET /api/board/tickets/4801
```json
{
  "id": 4801,
  "key": "TK-4801",
  "title": "Bulk-assign clients to a rep",
  "description": "Select several clients in the list and assign them to one rep in a single action.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Dana Ruiz (Acme project-2, admin)",
  "comments": [
    {"id": 90801, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-22T10:00:00Z",
     "body": "Reassigning after someone leaves takes forever one client at a time."},
    {"id": 90830, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-22T10:01:00Z",
     "body": "[AI Triage] Does the bulk action need an undo, or is re-assigning back enough?"},
    {"id": 90905, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-24T13:09:00Z",
     "body": "Re-assigning back is fine, no undo needed."}
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-2
2 (0 build(s) running, 2 box slot(s))
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ ls /root/harness/builds/project-2-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-2 --state all --search "TK-4801"
#641  TK-4801 bulk assign clients to a rep  OPEN  partner-dev  2026-08-24T07:02:00Z
$ git ls-remote --heads origin "*TK-4801*"
7c1f92a3  refs/heads/TK-4801-bulk-assign
$ gh pr view 641 -R example-org/project-2 --json files,author
{"author":{"login":"partner-dev"},"files":["src/app/clients/page.tsx","src/app/api/clients/bulk-assign/route.ts","tests/clients/bulk-assign.test.ts"]}
$ curl -s -X POST .../v1/acquire -d '{"key":"project-2:TK-4801","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
