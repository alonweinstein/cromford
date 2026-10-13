# Build results + board state — tick at 2026-08-24T09:40:00Z

## Board fingerprint
Re-checked at the start of this tick: **unchanged** since the last consumed tick
(`gate-diff.sh` exit 2). No ticket moved on the board.

## cat /root/harness/builds/project-2-TK-4770-20260824T0910/RESULT
```
PR_MERGED https://github.com/example-org/project-2/pull/633
TICKET: TK-4770
TIER: 1
PLAN: docs plan accepted; acceptance tests in tests/documents/expiry.test.ts
TESTS: 14 passed (npm run test:unit), typecheck clean
QA: /clients/[id]/documents — expiry badge renders on an expired doc, hidden otherwise
DEPLOY: production serves the badge at https://os.project-2.example/clients/c_8812/documents
```

## ls /root/harness/builds/project-2-TK-4770-20260824T0910/
```
RESULT  plan.md  review.md  cost.csv  execute.out
(no COMMENTED marker)
```

## GET /api/board/tickets/4770
```json
{
  "id": 4770, "key": "TK-4770", "title": "Show an expiry badge on client documents",
  "status": "in_progress", "waitingOn": "team", "triageVerdict": "ready",
  "reporter": "Dana Ruiz (Acme project-2, admin)",
  "comments": [
    {"id": 89440, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-19T11:00:00Z",
     "body": "We keep chasing clients for documents that already expired. Flag them in the list."},
    {"id": 89502, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-19T11:01:00Z",
     "body": "[AI Triage] Confirmed: badge on the documents list when expiresAt is in the past. Ready to build."}
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-2
2 (0 build(s) running, 2 box slot(s))
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ curl -s -o /dev/null -w "%{http_code}" https://os.project-2.example/clients/c_8812/documents
200
```
