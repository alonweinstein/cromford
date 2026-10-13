# Greenfield stage: IDEATE — one department (the future OS, from scratch)

You are designing what an AI Operating System should DO for one department of an organization that has no OS yet: `$DEPT`. Walk its Company Map section role by role, process by process, and produce 2-4 strong OS capabilities we would build for them. Write ONE file: `$IDEAS_OUT`.

## Inputs (paths in RUNTIME CONTEXT)
- `$MAP` — full map for company frame; work ONLY your department's section + its uncovered accountabilities.
- `$SIGNALS` — evidence tagged to your department (pain, risk, ambition, numbers).
- `$CATALOG` — the cross-portfolio feature library: what we've PROVEN in production for 7 sibling OSs. Greenfield ideas should lean hard on this — proposing proven features in this client's vocabulary is the point, not novelty.
- `$LEDGER` — prior runs' ideas for this workspace (dedup: never re-propose non-candidate/expired slugs).

## The walk (per role, per process)
1. What do they use TODAY (map's "current tooling") and where does it strain (signals)?
2. **AAA ladder** in order: what would we **Automate** (the hands), where do we **Augment** the human (the suit), what could earn **Autonomy** (the brain)?
3. Which catalog features map onto this process (name the source OS pattern in `prd_notes`, e.g. "port: project-2 live-coach", "project-6 primitive: P3 ledger")?

## DERISK → UNCLOG → SCALE (classify every idea)
Same Functional Technology Framework as always — and for a greenfield org DERISK carries extra weight because nothing has been derisked yet:
- **`derisk` — "Remove what can kill you."** Key-person dependencies, client data in email/spreadsheets, no audit trail, shared credentials, single points of failure, compliance gaps. **Security is a standing sweep:** every process where money or client data moves through an unverified channel is a derisk candidate. Reserved for genuine can-kill-you items.
- **`unclog` — "Remove what's slowing you down."** Double entry, manual handoffs, spreadsheet chokepoints, "only X knows how".
- **`scale` — "Now grow."** The capabilities their stated ambitions need — only credible because the first two are sequenced ahead of it.
Cross-check AAA↔DUS (automation↔derisk/unclog, augmentation↔unclog/scale, autonomy↔scale).

## Scoring
`impact` 1-10 anchored to THIS org (9-10 = touches revenue/compliance or the owner's week; 5-6 = one role's convenience). `effort` in AI build sessions assuming the project-6/portfolio chassis (proven ports are cheap — score them honestly cheap). `confidence` = evidence strength from signals.

## Output — `$IDEAS_OUT`
Same schema as OS ideation (`slug`,`title` in the client's vocabulary,`summary`,`department`,`role`,`process`,`aaa`,`dus`,`dus_why`,`source`,`evidence`,`impact`,`effort`,`confidence`,`prd_notes` incl. catalog/primitive mapping). 2-4 ideas, every one evidence-backed.

Final line: `IDEATE_DONE dept=$DEPT n=<count>` or `IDEATE_FAILED <reason>`.
