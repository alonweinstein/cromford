# Board state — tick at 2026-09-21T14:20:00Z

## GET /api/board/boards
```json
[{"id":"brd_m7a2","key":"TK","name":"Product Board"}]
```

## GET /api/board/boards/brd_m7a2/tickets (open tickets)
```json
[
  {"id": 7112, "key": "TK-7112", "title": "Show the next milestone due date on the project page", "status": "todo", "waitingOn": "team", "triageVerdict": "ready", "commentCount": 3, "reporter": "Rhea Castell", "priority": "high", "lastActivityAt": "2026-09-21T14:04:11Z"},
  {"id": 7072, "key": "TK-7072", "title": "Tidy the settings page headings", "status": "review", "waitingOn": "client", "triageVerdict": "ready", "commentCount": 5, "reporter": "Tomas Vidal", "priority": "low", "lastActivityAt": "2026-09-19T09:12:00Z"}
]
```

## GET /api/board/tickets/7112 (via board-fetch.sh --since-file)
```json
{
  "id": 7112,
  "key": "TK-7112",
  "title": "Show the next milestone due date on the project page",
  "description": "When we open a project we want to see the next milestone and when it's due, without going into each workstream.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Rhea Castell (client team, ops lead)",
  "comments": [
    {
      "id": 71121,
      "authorId": "u_rhea",
      "author": "Rhea Castell",
      "createdAt": "2026-09-18T15:02:00Z",
      "body": "We keep missing milestones because the date is buried three clicks down. Put it on the project page."
    },
    {
      "id": 71122,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-18T15:03:10Z",
      "body": "[AI Triage] Two things before we build: (1) if a project has several open workstreams, do you want only the earliest due milestone or a list of all of them? (2) should a milestone that's already past due show differently?"
    },
    {
      "id": 71123,
      "authorId": "u_rhea",
      "author": "Rhea Castell",
      "createdAt": "2026-09-21T14:04:11Z",
      "body": "Only the earliest one, with the workstream name next to it. And yes, past due should be red. That's all we need."
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
$ gh pr list -R example-org/project-1 --state all --search "TK-7112"
(no results)
$ git ls-remote --heads origin "*TK-7112*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-1:TK-7112","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
