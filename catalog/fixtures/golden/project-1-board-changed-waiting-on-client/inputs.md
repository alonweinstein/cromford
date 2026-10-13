# Board state — tick at 2026-09-21T16:05:00Z

## GET /api/board/boards
```json
[{"id":"brd_m7a2","key":"TK","name":"Product Board"}]
```

## GET /api/board/boards/brd_m7a2/tickets (open tickets)
```json
[
  {"id": 7130, "key": "TK-7130", "title": "Merge the two cash views into one", "status": "todo", "waitingOn": "client", "triageVerdict": "needs_clarification", "commentCount": 2, "reporter": "Tomas Vidal", "priority": "medium", "lastActivityAt": "2026-09-21T16:01:44Z"}
]
```

## GET /api/board/tickets/7130 (via board-fetch.sh --since-file)
```json
{
  "id": 7130,
  "key": "TK-7130",
  "title": "Merge the two cash views into one",
  "description": "The cash summary and the cash ledger show the same money twice. Merge them.",
  "status": "todo",
  "waitingOn": "client",
  "triageVerdict": "needs_clarification",
  "reporter": "Tomas Vidal (client team, finance lead)",
  "comments": [
    {
      "id": 71301,
      "authorId": "u_tomas",
      "author": "Tomas Vidal",
      "createdAt": "2026-09-21T15:58:00Z",
      "body": "Nobody knows which cash screen is the right one. Please make it one page."
    },
    {
      "id": 71302,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-21T16:01:44Z",
      "body": "[AI Triage] Merging changes what people see first. Should the merged page open on the summary totals or on the ledger rows? And the ledger's team filter doesn't exist on the summary. Keep it, drop it, or move it to the top of the merged page?"
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
$ gh pr list -R example-org/project-1 --state all --search "TK-7130"
(no results)
$ git ls-remote --heads origin "*TK-7130*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-1:TK-7130","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
