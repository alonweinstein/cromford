# Greenfield stage: DECK — the pre-sales proposal pack

Assemble everything this run produced into ONE self-contained HTML document the operator can present or send: the client's own operating system, shown to them before they've signed. Write ONE file: `$DECK_OUT`. Inputs in RUNTIME CONTEXT: `$MAP`, `$SIGNALS`, `$IDEAS` (final scored list), `$MOCKUP_DIR` (mockup HTML files for the top ideas).

## Structure (sticky top TOC with anchor links)
1. **What we heard** — the company in one page: business model, the 3 numbers that matter, the org at a glance (departments → roles). Their words, quoted.
2. **What's at stake** — the strongest signals as short evidence cards (pain / risk / ambition), each with its verbatim quote and who said it.
3. **The plan: DERISK → UNCLOG → SCALE** — explain the sequence in one tight paragraph (remove what can kill you → remove what slows you down → now grow; scaling a fragile, bottlenecked business just breaks it faster). Then the full project list as three color-coded groups (derisk red, unclog amber, scale green): title, one-line summary, department, impact/effort/confidence, evidence pointer.
4. **See it** — for each top idea with a mockup: a short intro paragraph, then the mockup embedded INLINE via `<iframe srcdoc="...">` (HTML-escape the mockup file's full contents into the srcdoc attribute; give the iframe a fixed responsive height with its own scroll). The deck must stay one single file.
5. **The 90 days** — DERISK items as days 1-30, UNCLOG 30-60, SCALE 60-90, as a simple three-column (stacked on mobile) timeline. Effort totals in AI build sessions per phase.
6. **Open questions** — from the map, framed as "what we'd confirm in our next conversation".

## Design standard
Self-contained (inline CSS, zero external assets). #FCFCFC background, #1A1A1A ink, #2563EB accent, 920px column, card/pill components, generous whitespace. DUS colors: derisk #DC2626, unclog #D97706, scale #059669 (pills + section accents). Fully readable at 375px — no horizontal body scroll anywhere; the mockup iframes scroll inside their own containers. Warm, direct, first-person-plural voice; near-zero em dashes; no AI-isms; no hype adjectives — the evidence does the selling.

Final line: `DECK_DONE` or `DECK_FAILED <reason>`.
