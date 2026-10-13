# Board state — tick at 2026-09-21T14:20:00Z

## GET /api/feature-board/boards
```json
[{"id":"fb_o19c","key":"TK","name":"Feature Requests"}]
```

## GET /api/feature-board/boards/fb_o19c/tickets (open tickets)
```json
[
  {"id": 7214, "key": "TK-7214", "title": "Let coordinators reschedule a booking from the calendar", "status": "todo", "waitingOn": "team", "triageVerdict": "ready", "commentCount": 3, "reporter": "Noa Klein", "priority": "high", "lastActivityAt": "2026-09-21T14:04:11Z"},
  {"id": 7174, "key": "TK-7174", "title": "Tidy the settings page headings", "status": "review", "waitingOn": "requester", "triageVerdict": "ready", "commentCount": 5, "reporter": "Idan Shor", "priority": "low", "lastActivityAt": "2026-09-19T09:12:00Z"}
]
```

## GET /api/feature-board/tickets/7214
```json
{
  "id": 7214,
  "key": "TK-7214",
  "title": "Let coordinators reschedule a booking from the calendar",
  "description": "Coordinators should be able to drag a booking to a new time instead of cancelling and rebooking.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Noa Klein (project-3 staff, customer support)",
  "comments": [
    {
      "id": 72141,
      "authorId": "u_noa",
      "author": "Noa Klein",
      "createdAt": "2026-09-18T15:02:00Z",
      "body": "Every reschedule is a cancel plus a new booking, and the customer gets two emails. Let them move it."
    },
    {
      "id": 72142,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-18T15:03:10Z",
      "body": "[AI Triage] Two questions: (1) when a booking moves, does the customer get one 'rescheduled' email, or no email at all? (2) can a coordinator move a booking into a slot outside their normal hours?"
    },
    {
      "id": 72143,
      "authorId": "u_noa",
      "author": "Noa Klein",
      "createdAt": "2026-09-21T14:04:11Z",
      "body": "One 'rescheduled' email with the new time. And no, only inside their normal hours. Nothing else changes."
    }
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-3
2 (box slots 2, 0 running, no wip limit)
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ ls /root/harness/builds/project-3-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-3 --state all --search "TK-7214"
(no results)
$ git ls-remote --heads origin "*TK-7214*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-3:TK-7214","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
