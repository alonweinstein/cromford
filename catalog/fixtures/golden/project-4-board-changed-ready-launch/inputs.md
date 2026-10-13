# Board state — tick at 2026-09-21T14:20:00Z

## GET /api/accounting/requests-board/boards
```json
[{"id":"rb_c4e8","slug":"feature-requests","key":"TK","name":"Feature Requests"}]
```

## GET /api/accounting/requests-board/boards/rb_c4e8/tickets (open tickets)
```json
[
  {"id": 7315, "key": "TK-7315", "title": "Add the vendor's payment terms to the bill detail page", "status": "todo", "waitingOn": "team", "triageVerdict": "ready", "commentCount": 3, "reporter": "Maya Lindqvist", "priority": "high", "lastActivityAt": "2026-09-21T14:04:11Z"},
  {"id": 7275, "key": "TK-7275", "title": "Tidy the settings page headings", "status": "review", "waitingOn": "requester", "triageVerdict": "ready", "commentCount": 5, "reporter": "Owen Brandt", "priority": "low", "lastActivityAt": "2026-09-19T09:12:00Z"}
]
```

## GET /api/accounting/requests-board/tickets/7315
```json
{
  "id": 7315,
  "key": "TK-7315",
  "title": "Add the vendor's payment terms to the bill detail page",
  "description": "When I open a bill I want to see the vendor's payment terms (net 15, net 30) so I know when to pay.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Maya Lindqvist (finance team, AP lead)",
  "comments": [
    {
      "id": 73151,
      "authorId": "u_maya",
      "author": "Maya Lindqvist",
      "createdAt": "2026-09-18T15:02:00Z",
      "body": "I keep opening the vendor record just to check the terms. Show them on the bill."
    },
    {
      "id": 73152,
      "authorId": "system-board",
      "author": "AI Triage",
      "createdAt": "2026-09-18T15:03:10Z",
      "body": "[AI Triage] Two things: (1) the vendor record has default terms, and some bills carry their own terms. Which one wins when both exist? (2) should the bill also show the computed due date?"
    },
    {
      "id": 73153,
      "authorId": "u_maya",
      "author": "Maya Lindqvist",
      "createdAt": "2026-09-21T14:04:11Z",
      "body": "The bill's own terms win if it has them, otherwise the vendor default. Yes, show the due date too. That's it."
    }
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-4
2 (box slots 2, 0 running, no wip limit)
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ ls /root/harness/builds/project-4-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-4 --state all --search "TK-7315"
(no results)
$ git ls-remote --heads origin "*TK-7315*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-4:TK-7315","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
