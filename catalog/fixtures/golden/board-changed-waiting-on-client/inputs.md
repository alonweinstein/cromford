# Board state — tick at 2026-08-24T16:05:00Z

## GET /api/board/boards
```json
[{"id":"pb-board-1","key":"TK","name":"Product Board"}]
```

## GET /api/board/boards/pb-board-1/tickets (open tickets)
```json
[
  {"id":4830,"key":"TK-4830","title":"Drop the manual-discount toggle from the proposal form","status":"todo","waitingOn":"client","triageVerdict":"needs_clarification","commentCount":2,"reporter":"Dana Ruiz","priority":"medium","lastActivityAt":"2026-08-24T16:01:44Z"},
  {"id":4805,"key":"TK-4805","title":"Rename 'Engagement' to 'Plan' in the client nav","status":"review","waitingOn":"client","triageVerdict":"ready","commentCount":6,"reporter":"Dana Ruiz","priority":"low","lastActivityAt":"2026-08-22T09:12:00Z"}
]
```

## GET /api/board/tickets/4830 (via board-fetch.sh --since-file)
```json
{
  "id": 4830,
  "key": "TK-4830",
  "title": "Drop the manual-discount toggle from the proposal form",
  "description": "The manual-discount toggle confuses reps. Get rid of it.",
  "status": "todo",
  "waitingOn": "client",
  "triageVerdict": "needs_clarification",
  "reporter": "Dana Ruiz (Acme project-2, admin)",
  "comments": [
    {"id": 92010, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-24T15:58:00Z",
     "body": "Nobody uses the manual-discount toggle and half the team turns it on by accident. Please remove it."},
    {"id": 92011, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-24T16:01:44Z",
     "body": "[AI Triage] Removing the toggle changes how a rep sets a non-standard fee. Does the fee field stay editable without the toggle, does it become admin-only, or does the whole override go away? Existing proposals that already carry an override — keep their number or reset to the rate card?"}
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
```
