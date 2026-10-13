# Greenfield stage: SIGNALS (evidence from discovery materials)

Mine the workspace `materials/` (discovery-call transcripts, org docs, emails, questionnaires — paths in RUNTIME CONTEXT) for EVIDENCE of pain, risk, and ambition. No ideation — verbatim quotes and concrete pointers only. Write ONE file: `$SIGNALS_OUT`.

What counts as a signal in discovery materials:
1. **Pain said out loud** — complaints, workarounds, "we do this in a spreadsheet", "only X knows how", double entry, things that take days.
2. **Risk exposure** (source: `security`) — shared logins, key-person dependencies, client data in email/WhatsApp, no backups, compliance anxieties, access nobody revoked, vendor dependencies with no exit.
3. **Ambition** — growth goals, hiring plans, "we want to get to X" statements (these anchor SCALE ideas).
4. **Numbers** — revenue, headcount, volumes, error rates, time spent — anything quantified.

Tag every signal to the Company Map (`$MAP`): department key, role, process. Same schema as OS signals:

```json
{"signals":[{
  "id": "sig-1",
  "source": "transcript|doc|questionnaire|security",
  "evidence": "VERBATIM quote (with who said it) or precise doc pointer",
  "department": "<map dept key>", "role": "<role>", "process": "<process>",
  "theme": "one line", "strength": 7, "date": "YYYY-MM-DD or approx"
}]}
```

10-40 signals. `strength` 9-10 = the founder/owner said it explicitly; 6-8 = a team member said it or a doc shows it; ≤5 = inference. Never fabricate quotes.

Final line: `SIGNALS_DONE n=<count>` or `SIGNALS_FAILED <reason>`.
