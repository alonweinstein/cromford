## Filing tickets for out-of-band work
When something ships (or is being built) because of an ask that did NOT originate on the product board — a Telegram request from the operator, a chat instruction, an alert investigation that led to a fix — FILE A TICKET on the relevant board so the client-facing record stays complete:
- Search open tickets first; never file a duplicate.
- `POST .../boards/{boardId}/tickets` with a clear title and a description that states what was asked and what shipped (De-AI voice, direct production links, sample record URL for dynamic routes). Reporter shows as the system actor.
- Then post the what-shipped comment and set status per convention (`review` for anything with behavior/UX, `done` only for pure to-spec copy).
Creation is supported on all four boards (project-1 + project-2 via the internal-ticket-create PRs; project-3 + project-4 since their original ports).
