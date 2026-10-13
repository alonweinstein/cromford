# Archie's skills (BH-4064, wave 3 of #3966)

Each dir here is one skill the hub orchestrator (Archie) loads on demand.
`bin/harness-sync.sh` deploys them to `/root/orchestrator/.claude/skills/` on a
box that has `/root/orchestrator` (the hub), through `bin/sync-skills.sh` with
`SKILLS_SUBDIR=orchestrator/skills`. `replays/` is never deployed.

## Layout

```
orchestrator/skills/<name>/SKILL.md
orchestrator/skills/<name>/replays/<NN-slug>/input.md      the recorded situation
orchestrator/skills/<name>/replays/<NN-slug>/expected      VERDICT: <word>
orchestrator/skills/<name>/replays/<NN-slug>/recorded.txt  the recorded reply, last line VERDICT: <word>
```

SKILL.md frontmatter: `name:` (equal to the dir), `description:` (what Claude
Code reads to pick the skill), and `verdicts:`, a `|`-separated lowercase list.
An `expected` word outside that list fails the run. Each skill needs at least 2
cases. The cases shipped here are constructed situations written for the
replays, not copies of production records.

## Run

```
bin/archie-skill-replay.sh                     # every skill
bin/archie-skill-replay.sh --skill cost-watch  # one skill
```

It prints `PASS`/`FAIL` per case and ends with
`archie-skill-replay: <n> skills, <p> passed, <f> failed`; rc 0 only when
nothing failed. The model is `$ARCHIE_REPLAY_MODEL_CMD <prompt-file> <case-dir>`;
unset, it replays `recorded.txt`, so no vendor is called. The prompt is the
SKILL.md body, `=== CASE ===`, `input.md`, and a closing `VERDICT:` instruction.
The suite is `tests/archie-skill-replays.bh-4064-test.sh`.

## Learned on the hub (BH-4066, wave 5)

Archie changes a skill only through `bin/archie-learn.sh edit|correct` (a new
skill: `propose`, then `adopt` after the operator says yes). It stages the current
skill with its replays, adds any new case, and runs this runner over every
case with the live model `bin/archie-replay-model.sh` (stage `archie-replay`
through `bin/agent-call.sh`, a `model_routes` row, a sha256 spend ledger). Only
a fully green run promotes:

- the learned copy, SKILL.md plus replays, lives in
  `/root/orchestrator/learned/skills/<name>/`, and each promote's diff in
  `/root/orchestrator/learned/history/`;
- the live `/root/orchestrator/.claude/skills/<name>/SKILL.md` gets a
  `.archie-learned` marker, and `bin/sync-skills.sh` skips a marked skill, so a
  deploy never puts the repo's older copy back.

A learned skill stops taking repo updates until someone upstreams it in a PR.
Once the repo's SKILL.md matches the live one byte for byte, `bin/sync-skills.sh`
clears the marker (`upstreamed: <name>`) and later repo changes deploy again.
The weekly learning report lists every marked skill the repo does not carry yet,
so that is not forgotten.
