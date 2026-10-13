---
name: triage-thread
description: Decide whether a product-board ticket is ready to build by reading its whole thread, status, waitingOn and triageVerdict first. Use before building, scoping or folding any ticket into other work.
verdicts: buildable | waiting-on-client | hold
---

# Triage a ticket thread

Never decide from the title or the description. The thread is the ticket.

## Steps

1. Read the body, every comment in order, the status, `waitingOn` and
   `triageVerdict`.
2. Find the latest turn. Thread recency is law: a later comment overrides an
   earlier one, the description included.
3. If the latest word on the ticket is a HOLD (from the operator, the client, or a HOLD
   label or comment that was never RESUMEd), the answer is `hold`.
4. If triage asked the client a question and the client has not answered it
   (`triageVerdict = needs_clarification`, `waitingOn = client`, or an open
   question as the last turn), the answer is `waiting-on-client`. This holds even
   when the direction looks obvious. an early engagement ("remove the discount toggle")
   was built while triage's question about how the rep sets the discount was still
   open, and it was wrong.
5. Only when the client's answer, or a clear spec with no open question, is the
   latest turn, the answer is `buildable`.
6. Say in one or two sentences which comment decided it, quoting it.

## Verdicts

- `buildable`: nothing open, the latest turn is an answer or a ready spec.
- `waiting-on-client`: a question to the client is still open.
- `hold`: someone with the authority to stop it said stop.

## Voice

Plain English, short sentences, no em dashes. Quote the comment that decided it.
