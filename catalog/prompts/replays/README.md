# Replays for lane prompts

This root holds recorded replay cases for the lane prompts in
`catalog/prompts/`. Each lane prompt that has cases gets its own directory
here, in the layout of `orchestrator/skills/` (see `orchestrator/skills/README.md`):
`<name>/SKILL.md` plus `<name>/replays/<NN-slug>/{input.md,expected,recorded.txt}`.

It is not under `orchestrator/skills/` on purpose. `bin/sync-skills.sh` deploys
that tree to the hub as live skills, and these are not skills.

The `SKILL.md` frontmatter here carries `prompt: <path> [<path> ...]`. The paths
are repo-relative. `bin/archie-skill-replay.sh` builds the prompt head from them,
in order, instead of from the SKILL.md body. A file adds its bytes and a newline.
A directory adds its `*.md` files in glob order and one newline, so
`prompts/archie-soul.d` reads the same way `bin/archie.sh` reads it. An
absolute path, a path with `..`, or a path that is not readable under the repo
is a structural FAIL, and that skill's cases do not run.

Run every case here with the recorded replies (no vendor call):

    bin/archie-skill-replay.sh --root catalog/prompts/replays

Each sibling slice of #4760 adds its own directory here. Do not edit a list.
