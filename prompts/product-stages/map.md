# Stage: COMPANY MAP (Phase 0 — monthly, or when missing)

Build or refresh the **Company Map** — the durable org model the AI product team ideates from: company → departments → roles → accountabilities → processes → current OS coverage. Write ONE file: `$MAP_OUT` (path in RUNTIME CONTEXT). Read-only everywhere else; never modify the repo.

Sources, in order:
1. The app repo (path in project context): CLAUDE.md module state, `prisma/schema.prisma` (or `prisma/schema/*.prisma`) org/role/agent models, the nav/app-map, agent registry + seed scripts, SOP/brain content where present.
2. The live board (existing tickets show who the humans are and what they own).
3. The project context appended below (client profile, department hints).

## Output format — exactly this shape

```
---
project: <project>
updated: <YYYY-MM-DD>
departments: [<kebab-key>, <kebab-key>, ...]
---
# Company Map — <Client Name>

## Business model
<Revenue engines, who pays for what, rough headcount, the 3 numbers that matter most to the owner.>

## Department: <kebab-key>
**Mission:** <one line>
### Roles
- **<Role name>** — <accountabilities, comma-dense>
  - Process: <name> — <what happens, who's involved> → **OS coverage:** <route/screen/agent by real name, or "none">
  - Process: ...
(repeat Roles per department; one `## Department:` section per key in the frontmatter list)

## Uncovered accountabilities
- <dept>/<role>: <accountability with NO OS surface or agent> (standing ideation targets)
```

## Rules
- 4-10 departments, kebab-case keys, every frontmatter key has a matching `## Department:` section.
- Use REAL role names where the org data has them (pods/business roles/agent registry/seed data); don't invent people.
- OS coverage is honest: name the actual route or agent key, or write "none". A vague "partially covered" is banned — say what exists and what's missing.
- **the operator edits this file by hand.** Keep it dense and factual, keep the structure stable, and when REFRESHING an existing map (its current content is in RUNTIME CONTEXT), preserve manually-added or corrected lines unless the codebase proves them wrong — his corrections are ground truth.

Final line of your reply: `MAP_DONE departments=<n>` or `MAP_FAILED <reason>`.
