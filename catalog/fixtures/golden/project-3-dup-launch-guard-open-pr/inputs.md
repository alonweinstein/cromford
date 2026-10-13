# Board state — tick at 2026-09-21T13:15:00Z

## GET /api/feature-board/boards
```json
[{"id":"fb_o19c","key":"TK","name":"Feature Requests"}]
```

## GET /api/feature-board/tickets/7203
```json
{
  "id": 7203,
  "key": "TK-7203",
  "title": "Filter the customer list by plan tier",
  "description": "I need to see just the annual-plan customers when I send the renewal notes.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Noa Klein (project-3 staff, customer support)",
  "comments": [
    {
      "id": 72031,
      "authorId": "u_noa",
      "author": "Noa Klein",
      "createdAt": "2026-09-19T10:00:00Z",
      "body": "I need to see just the annual-plan customers when I send the renewal notes."
    },
    {
      "id": 72032,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-19T10:01:00Z",
      "body": "[AI Triage] Should the filter allow picking several tiers at once, or one at a time?"
    },
    {
      "id": 72033,
      "authorId": "u_noa",
      "author": "Noa Klein",
      "createdAt": "2026-09-21T13:09:00Z",
      "body": "One at a time is fine."
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
$ gh pr list -R example-org/project-3 --state all --search "TK-7203"
#412  TK-7203 filter the customer list by plan tier  OPEN  partner-dev  2026-09-21T07:02:00Z
$ git ls-remote --heads origin "*TK-7203*"
7c1f92a3  refs/heads/TK-7203-filter
$ gh pr view 412 -R example-org/project-3 --json files,author
{"author":{"login":"partner-dev"},"files":["src/app/customers/page.tsx","src/lib/customers/filters.ts","tests/customers/tier-filter.test.ts"]}
$ curl -s -X POST .../v1/acquire -d '{"key":"project-3:TK-7203","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
