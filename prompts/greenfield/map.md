# Greenfield stage: COMPANY MAP (day zero — no OS, no repo, no board)

Build the Company Map for a NEW organization from its discovery materials: call transcripts, org docs, questionnaires, anything in the workspace `materials/` dir (paths in RUNTIME CONTEXT). This map becomes the spine of the engagement — the assessment, the proposal pack, and eventually the project-6 build all derive from it. Write ONE file: `$MAP_OUT`.

Use the SAME format as OS company maps:

```
---
project: <client-slug>
updated: <YYYY-MM-DD>
greenfield: true
departments: [<kebab-key>, ...]
---
# Company Map — <Client Name>

## Business model
<Revenue engines, who pays for what, headcount, the 3 numbers that matter most to the owner — from the materials, with honest "unknown" where the materials don't say.>

## Department: <kebab-key>
**Mission:** <one line>
### Roles
- **<Role/person name>** — <accountabilities>
  - Process: <name> — <what happens, who's involved, what tools they use TODAY> → **Current tooling:** <spreadsheet/email/SaaS-name/tribal knowledge/none>
  - ...

## Uncovered accountabilities
- <dept>/<role>: <accountability handled by memory, spreadsheets, or nobody — the OS opportunity surface>

## Key people
- <Name> — <role, what they own, anything notable from the materials>

## Open questions
- <what the discovery materials DON'T answer that the next call should — numbered, specific>
```

Rules:
- Ground everything in the materials — quote-level fidelity for names, numbers, tools. Where you infer, mark it `(inferred)`. Where you don't know, say unknown — a wrong map poisons the whole engagement; an honest gap becomes a discovery question.
- "Current tooling" replaces OS coverage: for a greenfield org the finding is what they use TODAY (and where it strains).
- 4-10 departments. Real people's names where the materials give them.
- the operator edits this file by hand; keep it dense, stable in structure, and preserve his edits on refresh (existing map, if any, is in RUNTIME CONTEXT).

Final line: `MAP_DONE departments=<n>` or `MAP_FAILED <reason>`.
