# Board + queue state — tick at 2026-08-24T12:30:00Z

## Board fingerprint
Re-checked at the start of this tick: **unchanged** since the last consumed tick
(`gate-diff.sh` exit 2). No ticket moved on the board.

## GET /api/board/tickets/4795
```json
{
  "id": 4795, "key": "TK-4795", "title": "Email reminder when a client document is 7 days overdue",
  "status": "todo", "waitingOn": "team", "triageVerdict": "ready",
  "reporter": "Dana Ruiz (Acme project-2, admin)",
  "comments": [
    {"id": 90610, "authorId": "u_dana", "author": "Dana Ruiz", "createdAt": "2026-08-23T13:00:00Z",
     "body": "If a client hasn't uploaded a requested doc after a week, email them once. Copy is in the attached doc."},
    {"id": 90680, "authorId": "system", "author": "AI Triage", "createdAt": "2026-08-24T08:15:00Z",
     "body": "[AI Triage] Copy and cadence confirmed (one email, day 7, no repeats). Ready to build."}
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-2
0 (2 build(s) running, 2 box slot(s))
$ ps -o etime= -p $(pgrep -f "run-build.sh project-2" | tr '\n' ' ')
   00:41:12
   00:12:55
$ ls /root/harness/builds/project-2-*/RESULT 2>/dev/null
(none — both running builds are still in EXECUTE)
$ gh pr list -R example-org/project-2 --state all --search "TK-4795"
(no results)
$ git ls-remote --heads origin "*TK-4795*"
(no results)
```
