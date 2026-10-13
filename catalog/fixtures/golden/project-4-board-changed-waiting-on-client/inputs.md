# Board state — tick at 2026-09-21T16:05:00Z

## GET /api/accounting/requests-board/boards
```json
[{"id":"rb_c4e8","slug":"feature-requests","key":"TK","name":"Feature Requests"}]
```

## GET /api/accounting/requests-board/boards/rb_c4e8/tickets (open tickets)
```json
[
  {"id": 7330, "key": "TK-7330", "title": "Stop auto-categorizing Stripe payouts", "status": "todo", "waitingOn": "requester", "triageVerdict": "needs_clarification", "commentCount": 2, "reporter": "Owen Brandt", "priority": "medium", "lastActivityAt": "2026-09-21T16:01:44Z"}
]
```

## GET /api/accounting/requests-board/tickets/7330
```json
{
  "id": 7330,
  "key": "TK-7330",
  "title": "Stop auto-categorizing Stripe payouts",
  "description": "The automatic category on Stripe payouts is wrong half the time. Turn it off.",
  "status": "todo",
  "waitingOn": "requester",
  "triageVerdict": "needs_clarification",
  "reporter": "Owen Brandt (finance team, controller)",
  "comments": [
    {
      "id": 73301,
      "authorId": "u_owen",
      "author": "Owen Brandt",
      "createdAt": "2026-09-21T15:58:00Z",
      "body": "The auto-category keeps putting Stripe payouts under revenue. Please stop it."
    },
    {
      "id": 73302,
      "authorId": "system-board",
      "author": "AI Triage",
      "createdAt": "2026-09-21T16:01:44Z",
      "body": "[AI Triage] Turning it off changes how every payout gets booked. Should new payouts land uncategorized for someone to review, or go to a fixed clearing account? And should we re-open the payouts it already categorized this quarter?"
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
$ gh pr list -R example-org/project-4 --state all --search "TK-7330"
(no results)
$ git ls-remote --heads origin "*TK-7330*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-4:TK-7330","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
