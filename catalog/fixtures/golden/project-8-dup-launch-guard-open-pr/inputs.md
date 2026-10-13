# Board state — tick at 2026-09-21T13:15:00Z

## GET /api/board/boards
```json
[{"id":"brd_ia31","key":"TK","name":"Product Board"}]
```

## GET /api/board/tickets/7401
```json
{
  "id": 7401,
  "key": "TK-7401",
  "title": "Sortable columns on the accounts table",
  "description": "I want to sort accounts by balance and by last activity date.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Lena Moreau (customer team, operations)",
  "comments": [
    {
      "id": 74011,
      "authorId": "u_lena",
      "author": "Lena Moreau",
      "createdAt": "2026-09-19T10:00:00Z",
      "body": "I want to sort accounts by balance and by last activity date."
    },
    {
      "id": 74012,
      "authorId": "system",
      "author": "AI Triage",
      "createdAt": "2026-09-19T10:01:00Z",
      "body": "[AI Triage] Every column sortable, or just balance and last activity?"
    },
    {
      "id": 74013,
      "authorId": "u_lena",
      "author": "Lena Moreau",
      "createdAt": "2026-09-21T13:09:00Z",
      "body": "Every column is fine."
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
$ gh pr list -R example-org/project-8 --state all --search "TK-7401"
#286  TK-7401 sortable columns on the accounts table  OPEN  operator  2026-09-21T07:02:00Z
$ git ls-remote --heads origin "*TK-7401*"
7c1f92a3  refs/heads/TK-7401-sortable
$ gh pr view 286 -R example-org/project-8 --json files,author
{"author":{"login":"operator"},"files":["src/app/accounts/page.tsx","src/components/accounts-table.tsx","tests/accounts/sort.test.tsx"]}
```
