# Upgrading

Upgrades come from the upstream repo into your fork. Nothing pulls upstream
for you. Once your fork's `main` moves, your boxes pick it up on their own.

## Pull the new version

```bash
git remote add upstream https://github.com/cromford-ai/cromford
git fetch upstream
git merge upstream/main
```

Rebase instead of merging if that's how you keep your fork. Then run the
leak guard and any tests you changed:

```bash
bash tests/no-client-identifiers-test.sh
```

## Check what the new version needs

```bash
bin/selfhost-install.sh --config selfhost.conf --dry-run
```

A resource the new version needs that isn't in your ledger shows as `create`.
A new required setting shows up as a refusal that names it. The
[deployment guide](SELF-HOST.md#9-upgrade) has the same steps.

## What a box picks up on its own

`bin/update-runners.sh` runs once a day on every box. It fast-forwards the
box's harness checkout to `main` of its `origin`, which is your fork. Then it
updates the model CLIs, re-renders the build rules from `rules/CLAUDE.md`, and
re-renders the crontabs. So once you push the merge to your fork, each box is
on the new version after its next daily run.

To pick it up sooner, run it on the box yourself:

```bash
bin/update-runners.sh
```
