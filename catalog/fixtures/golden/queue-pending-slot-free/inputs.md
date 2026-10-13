# Board + queue state — tick at 2026-08-24T11:10:00Z

## Board fingerprint
Re-checked at the start of this tick: **unchanged** since the last consumed tick
(`gate-diff.sh` exit 2). No ticket moved on the board.

## GET /api/board/tickets/4790
```json
{
  "id": 4790, "key": "TK-4790", "title": "Client-facing savings summary card",
  "status": "todo", "waitingOn": "team", "triageVerdict": "ready",
  "reporter": "Marc Feld (Acme project-2, ops)",
  "comments": [
    {"id": 90110, "authorId": "u_marc", "author": "Marc Feld", "createdAt": "2026-08-21T10:00:00Z",
     "body": "One card at the top of the client page: total projected savings for the year, and the date we last recalculated it."},
    {"id": 90140, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-21T10:01:00Z",
     "body": "[AI Triage] Confirmed scope. Depends on the savings_snapshot table from PR #612."}
  ]
}
```

## GET /api/board/tickets/4791
```json
{
  "id": 4791, "key": "TK-4791", "title": "CSV export of the quarterly savings table",
  "status": "todo", "waitingOn": "team", "triageVerdict": "ready",
  "reporter": "Marc Feld (Acme project-2, ops)",
  "comments": [
    {"id": 90210, "authorId": "u_marc", "author": "Marc Feld", "createdAt": "2026-08-23T16:20:00Z",
     "body": "Same columns you see on screen, plus the client id. CSV is fine, no Excel."},
    {"id": 90255, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-24T09:02:00Z",
     "body": "[AI Triage] Columns confirmed by the requester. Ready to build."}
  ]
}
```

## Harness state
```
$ gh pr view 612 -R example-org/project-2 --json state,mergedAt
{"state":"MERGED","mergedAt":"2026-08-24T08:41:00Z"}
$ /root/harness/bin/free-slots.sh project-2
2 (0 build(s) running, 2 box slot(s))
$ ls /root/harness/builds/project-2-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-2 --state all --search "TK-4790"
(no results)
$ gh pr list -R example-org/project-2 --state all --search "TK-4791"
(no results)
$ git ls-remote --heads origin "*TK-479*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-2:TK-4790","ttl_s":7200}'
HTTP 201 {"acquired":true}
$ curl -s -X POST .../v1/acquire -d '{"key":"project-2:TK-4791","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
