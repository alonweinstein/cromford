# Greenfield stage: MOCKUP — a screen from their future OS

Mock up the primary screen(s) of ONE proposed capability for an organization that has no OS yet — this is what they'll see in the pre-sales deck, so it must feel like THEIR software, not a template. Idea JSON and paths in RUNTIME CONTEXT. Write ONE file: `$MOCKUP_OUT`.

- Fully self-contained single HTML file: inline CSS, no external assets, no JS beyond trivial tab/section toggling.
- **Theme:** professional OS chrome (left sidebar with the client's real department names from the map, top bar with the client's company name) in a clean modern palette. If the materials mention brand colors, use them; otherwise a restrained default (near-white background, dark ink, one accent). Their people's REAL names and REAL vocabulary from the map/signals in the UI.
- Realistic FAKE data plausible for their domain and volumes (use the numbers from signals as anchors — if they said "400 clients", the list shows ~400 clients' pagination).
- Responsive: perfect at 1280px AND 375px; no horizontal body scroll; tables scroll in their own container; sortable-header affordances; rows that look clickable.
- A slim fixed banner: 'CONCEPT — your future OS' (subtle).
- 2-3 key screens max as tabbed sections if the capability needs them.

Final line: `MOCKUP_DONE` or `MOCKUP_FAILED <reason>`.
