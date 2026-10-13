# Board state — tick at 2026-09-21T14:20:00Z

## GET /api/board/boards
```json
[{"id":"brd_ia31","key":"TK","name":"Product Board"}]
```

## GET /api/board/boards/brd_ia31/tickets (open tickets)
```json
[
  {"id": 7412, "key": "TK-7412", "title": "Show the account's total annual cost on the plan summary", "status": "todo", "waitingOn": "team", "triageVerdict": "ready", "commentCount": 3, "reporter": "Lena Moreau", "priority": "high", "lastActivityAt": "2026-09-21T14:04:11Z"},
  {"id": 7372, "key": "TK-7372", "title": "Tidy the settings page headings", "status": "review", "waitingOn": "client", "triageVerdict": "ready", "commentCount": 5, "reporter": "Grant Oduya", "priority": "low", "lastActivityAt": "2026-09-19T09:12:00Z"}
]
```

## GET /api/board/tickets/7412
```json
{
  "id": 7412,
  "key": "TK-7412",
  "title": "Show the account's total annual cost on the plan summary",
  "description": "Account managers want the total annual cost for a customer on the plan summary, not just per seat.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Lena Moreau (customer team, operations)",
  "comments": [
    {
      "id": 74121,
      "authorId": "u_lena",
      "author": "Lena Moreau",
      "createdAt": "2026-09-18T15:02:00Z",
      "body": "Clients ask what they pay in total and we add it up by hand. Put the total on the plan summary."
    },
    {
      "id": 74122,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-18T15:03:10Z",
      "body": "[AI Triage] Two questions: (1) should the total include add-on usage, or only the base subscription? (2) annual in dollars, as a percent of list price, or both?"
    },
    {
      "id": 74123,
      "authorId": "u_lena",
      "author": "Lena Moreau",
      "createdAt": "2026-09-21T14:04:11Z",
      "body": "Only the base subscription. Show both, dollars first. Nothing else on the page changes."
    }
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-8
2 (box slots 2, 0 running, no wip limit)
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ ls /root/harness/builds/project-8-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-8 --state all --search "TK-7412"
(no results)
$ git ls-remote --heads origin "*TK-7412*"
(no results)
```
