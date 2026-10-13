# Board state — tick at 2026-08-24T14:20:00Z

## GET /api/board/boards
```json
[{"id":"pb-board-1","key":"TK","name":"Product Board"}]
```

## GET /api/board/boards/pb-board-1/tickets (open tickets)
```json
[
  {"id":4812,"key":"TK-4812","title":"Fee override on the proposal screen","status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":4,"reporter":"Dana Ruiz","priority":"high","lastActivityAt":"2026-08-24T14:04:11Z"},
  {"id":4805,"key":"TK-4805","title":"Rename 'Engagement' to 'Plan' in the client nav","status":"review","waitingOn":"client","triageVerdict":"ready","commentCount":6,"reporter":"Dana Ruiz","priority":"low","lastActivityAt":"2026-08-22T09:12:00Z"},
  {"id":4788,"key":"TK-4788","title":"Quarterly savings export","status":"in_progress","waitingOn":"team","triageVerdict":"ready","commentCount":9,"reporter":"Marc Feld","priority":"medium","lastActivityAt":"2026-08-21T17:40:00Z"}
]
```

## GET /api/board/tickets/4812 (via board-fetch.sh --since-file)
```json
{
  "id": 4812,
  "key": "TK-4812",
  "title": "Fee override on the proposal screen",
  "description": "Reps need to set a one-off fee on a proposal when the standard rate doesn't apply. Today the number is locked to the rate card.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Dana Ruiz (Acme project-2, admin)",
  "comments": [
    {"id": 91201, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-20T15:02:00Z",
     "body": "The rate card is right most of the time but we lose deals when we can't discount. Let the rep type the fee."},
    {"id": 91240, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-20T15:03:10Z",
     "body": "[AI Triage] Two things before we build: (1) who can set the override — every rep, or only an admin? (2) does the override need an audit trail on the proposal?"},
    {"id": 91388, "authorId": "u_operator", "author": "the operator", "createdAt": "2026-08-22T08:11:00Z",
     "body": "Dana, whenever you get a minute — the two questions above are the whole spec."},
    {"id": 91455, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-24T14:04:11Z",
     "body": "Any rep can set it, no approval step. And yes, log who changed it and when, we get asked in reviews. Nothing else changes."}
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
$ gh pr list -R example-org/project-2 --state all --search "TK-4812"
(no results)
$ git ls-remote --heads origin "*TK-4812*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-2:TK-4812","ttl_s":7200}'
HTTP 201 {"acquired":true,"token":"lk_9f21"}
```
