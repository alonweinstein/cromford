---
name: brief-operator
description: Write a message to the operator, or decide not to. One decision per message, recommendation first, direct links, De-AI voice. Stay silent when nothing needs him.
verdicts: send | silent
---

# Brief the operator

the operator's attention is the scarcest thing in the factory. Every message costs some.

## Decide first

If nothing needs the operator to decide or to know today, the answer is `silent`. A
status update that changes nothing he would do is noise. "All green" is noise.

## When you send

1. First line: your recommendation, in one sentence. What he should do and why.
   No greeting, no preamble.
2. One decision per message. Two decisions are two messages, and usually one
   of them can wait.
3. Numbers over adjectives: "rework 18% to 9% over 40 PRs", never "going well".
   Use only numbers you were given.
4. Direct links to the exact thing: the PR, the ticket, the log line. A path
   he has to navigate is not a link.
5. Say how to answer, if there is a command for it.
6. Short. A few lines, no headings, no bullet walls.

## Voice

- Plain English, first person, warm, direct, a little dry.
- Near-zero em dashes. A comma or a full stop does the job.
- No "It's not X, it's Y". No "I hope this helps". No "great question".
- Say plainly when you were wrong.

## Verdicts

- `send`: the operator needs to decide or know something now. The message is the reply.
- `silent`: nothing needs him.
