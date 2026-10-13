<!--
docs/AGENT-ARCHITECTURE-TEMPLATE.md — the agent-architecture contract, in the
shape every repo's copy takes.

HOW THIS FILE IS USED. `prompts/arch-audit.md` runs an audit against a target
repo and its required output is this template, filled in, committed at that
repo's root as `AGENT_ARCHITECTURE.md`. The filename and the casing are not a
preference: `bin/verification-map.sh` reads exactly `<repo>/AGENT_ARCHITECTURE.md`
and lists its sections by markdown heading into the primer a PLAN stage reads
(`state/<project>-context.md`). A contract named anything else, or written with
bold text where headings belong, is a contract no planner is ever shown — the
audit runs, the PR merges, and nothing tells you it went nowhere.

WHY THE CONTRACT EXISTS AT ALL. An agent with an under-specified task optimizes
for what is in its context. It copies the nearest pattern, edits the file that is
already open, takes the shortest path that compiles, leaves code it cannot see
the callers of, and follows an instruction even when obeying breaks an invariant
nobody put in front of it. Every one of those is rational given what it can see.
So the contract's job is not to ask for more care. It is to make the
locally-obvious change the globally-correct one, and to make the unsafe shortcut
FAIL — mechanically, with an error that names the supported pattern.

KEEP THIS TEMPLATE PROJECT-AGNOSTIC. It is copied into repos we have not read.
A framework path or a process name stated as fact inside a rule is a rule that
is false in most repos it lands in, and a contract that is visibly wrong on line
one is a contract nobody reads to line two. Stacks appear here only as marked
examples; the repo's real nouns go in "Named nouns", which is the section that
makes the rules obeyable.

FILLING IT IN: replace every <PLACEHOLDER>, delete this comment block, and leave
nothing in the mechanical-backing table marked PROSE-ONLY unless it truly is.
-->

# Agent architecture — <PROJECT NAME>

This is the architecture contract for this repository. It binds humans and
agents equally, and it is read before any change that crosses a module boundary,
adds a writer to shared state, or introduces a new surface.

The five rules below are the contract. The table at the bottom says, honestly,
which of them a machine currently enforces and which are still only words.

## The five rules

### Rule 1 — The conventional path is cheaper than the shortcut

Doing it the supported way must take less work than working around it. Where a
shortcut is currently easier, that is a defect in the tooling, not in the person
or agent who took it — file it and fix the ergonomics rather than adding a
sentence asking people to try harder.

In this repo, the conventional path for the common change is:

- <THE COMMON CHANGE> → <THE SUPPORTED WAY TO DO IT: the generator, the
  registry entry, the base class, the codemod>

### Rule 2 — Forbidden dependencies fail mechanically

Some import directions must never exist: layer inversions, a boundary between
processes or trust zones, a cycle. Those are not review conventions. Each one is
either enforced by a named check that fails the build, or it is listed in the
table below as debt — there is no third state where prose is treated as
enforcement.

Forbidden in this repo:

- `<LAYER A>` must never import from `<LAYER B>`
- no cycles among `<MODULE SET>`

### Rule 3 — One obvious writer per durable value

Anything that outlives a request — a persisted row, a cache entry, a file on
disk, a config value, a piece of shared in-memory state — has exactly one place
in the code that writes it. Everything else calls that place. Two writers to one
value is how state diverges in a way no reader can attribute, and it is the
single most expensive thing an agent can add, because the second writer always
looks locally correct.

Durable values and their one writer:

| durable value | its one writer |
|---|---|
| `<VALUE>` | `<PATH>` |

### Rule 4 — New product work is isolated files, not branches in shared roots

A new feature, tenant, integration, or variant goes in its own file(s) behind
the existing interface. It does not arrive as another `if` in a shared entry
point, another case in a central switch, or another flag threaded through a
common helper. Shared roots accumulate branches precisely because adding one is
the smallest possible diff — which is exactly why an agent will choose it every
time, and why the rule has to be stated rather than assumed.

Shared roots that must not grow branches:

- `<PATH>` — add a `<UNIT>` file instead, registered at `<REGISTRY>`

### Rule 5 — Exceptions are narrow, explicit, and reviewed as architecture changes

Every rule here can be broken, and breaking one costs the same thing every time:
a named, scoped exception in the PR, reviewed as a change to this contract
rather than as a change to a feature. Where a rule is backed by a CI check, the
escape hatch is the standard one — the `skip-guardrail` label **plus** a written
`Guardrail-Justification:` line in the PR body, both required, neither
sufficient alone. A contract with no way out gets deleted the first time it is
wrong; one with a silent way out is decoration.

## Named nouns

The rules above are only obeyable once they are about things this repo actually
has. Fill these in with the real names, and use these names everywhere else in
the repo's docs and prompts.

| concept | what it is called here | where it lives |
|---|---|---|
| the unit of product work | `<FEATURE-EQUIVALENT>` | `<PATH>` |
| the entry point(s) into the system | `<ENTRYPOINT-EQUIVALENT>` | `<PATH>` |
| the layer that may be imported by anything | `<SHARED/CORE-EQUIVALENT>` | `<PATH>` |
| the boundary nothing may cross | `<BOUNDARY-EQUIVALENT>` | `<PATH>` |
| the registry a new unit is announced in | `<REGISTRY-EQUIVALENT>` | `<PATH>` |

## Mechanical backing

What actually enforces each rule today. A rule with no check is written down as
debt, in the word `PROSE-ONLY (debt)` — never described as if the prose enforced
it. This column is the difference between a contract and a wish, and reading it
honestly is more useful than filling it optimistically.

| rule | enforced by | where |
|---|---|---|
| Rule 1 — conventional path is cheaper | `<CHECK OR PROSE-ONLY (debt)>` | `<CI STEP / PATH>` |
| Rule 2 — forbidden dependencies | `<CHECK OR PROSE-ONLY (debt)>` | `<CI STEP / PATH>` |
| Rule 3 — one obvious writer | `<CHECK OR PROSE-ONLY (debt)>` | `<CI STEP / PATH>` |
| Rule 4 — isolated files, not branches | `<CHECK OR PROSE-ONLY (debt)>` | `<CI STEP / PATH>` |
| Rule 5 — narrow explicit exceptions | `<CHECK OR PROSE-ONLY (debt)>` | `<CI STEP / PATH>` |

Examples of what belongs in the "enforced by" column, for calibration: a
zero-tolerance cycle check (e.g. `madge --circular`), a lint rule pinning layer
imports (e.g. eslint `no-restricted-imports`), a dependency-cruiser ruleset, a
grep-shaped CI step with an explicit threshold. Each one names a tool and a
threshold, which is what makes it able to block. Anything that would need a
human to weigh two readings belongs in the prose above, not here.

## Conflict shape

Pasted verbatim from `bin/arch-conflict-scan.sh`; proposals are filed by a
person, never by the audit.

<CONFLICT_SHAPE_OUTPUT>

## Changing this contract

Edits to this file are architecture changes: they are proposed in their own PR,
reviewed as such, and land with the check that backs them (or with the debt
marked). A rule quietly softened is worse than a rule removed, because everyone
downstream still believes it holds.
