# Board state — tick at 2026-09-21T16:05:00Z

## GET /api/feature-board/boards
```json
[{"id":"fb_o19c","key":"TK","name":"Feature Requests"}]
```

## GET /api/feature-board/boards/fb_o19c/tickets (open tickets)
```json
[
  {"id": 7231, "key": "TK-7231", "title": "Remove the signup survey step", "status": "todo", "waitingOn": "requester", "triageVerdict": "needs_clarification", "commentCount": 2, "reporter": "Idan Shor", "priority": "medium", "lastActivityAt": "2026-09-21T16:01:44Z"}
]
```

## GET /api/feature-board/tickets/7231
```json
{
  "id": 7231,
  "key": "TK-7231",
  "title": "Remove the signup survey step",
  "description": "The signup survey slows everyone down. Take it out.",
  "status": "todo",
  "waitingOn": "requester",
  "triageVerdict": "needs_clarification",
  "reporter": "Idan Shor (project-3 staff, scheduling lead)",
  "comments": [
    {
      "id": 72311,
      "authorId": "u_idan",
      "author": "Idan Shor",
      "createdAt": "2026-09-21T15:58:00Z",
      "body": "Half the new customers drop off at the survey. Please remove it from signup."
    },
    {
      "id": 72312,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-21T16:01:44Z",
      "body": "[AI Triage] Coordinators use the survey answers before a first booking. If it leaves signup, should it move to after the first booking, become optional, or go away entirely? And what happens to customers who already filled it in?"
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
$ gh pr list -R example-org/project-3 --state all --search "TK-7231"
(no results)
$ git ls-remote --heads origin "*TK-7231*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-3:TK-7231","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
