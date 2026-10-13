# Board state — tick at 2026-09-21T16:05:00Z

## GET /api/board/boards
```json
[{"id":"brd_ia31","key":"TK","name":"Product Board"}]
```

## GET /api/board/boards/brd_ia31/tickets (open tickets)
```json
[
  {"id": 7430, "key": "TK-7430", "title": "Drop the theme picker from onboarding", "status": "todo", "waitingOn": "client", "triageVerdict": "needs_clarification", "commentCount": 2, "reporter": "Grant Oduya", "priority": "medium", "lastActivityAt": "2026-09-21T16:01:44Z"}
]
```

## GET /api/board/tickets/7430
```json
{
  "id": 7430,
  "key": "TK-7430",
  "title": "Drop the theme picker from onboarding",
  "description": "The theme picker confuses new users. Remove it.",
  "status": "todo",
  "waitingOn": "client",
  "triageVerdict": "needs_clarification",
  "reporter": "Grant Oduya (customer team, account manager)",
  "comments": [
    {
      "id": 74301,
      "authorId": "u_grant",
      "author": "Grant Oduya",
      "createdAt": "2026-09-21T15:58:00Z",
      "body": "Users click through the picker without reading the labels. Please take it out of onboarding."
    },
    {
      "id": 74302,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-21T16:01:44Z",
      "body": "[AI Triage] The picker sets the starting dashboard layout. Without it, should the layout come from the signup answers alone, should the account manager pick it on the first call, or should everyone start on the default layout? And do existing users keep their current layout?"
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
$ gh pr list -R example-org/project-8 --state all --search "TK-7430"
(no results)
$ git ls-remote --heads origin "*TK-7430*"
(no results)
```
