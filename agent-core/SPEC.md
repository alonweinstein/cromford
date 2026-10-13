# agent-core: the agent anatomy

This file defines the parts of an always-on staff agent. Each section names the
function or schema in this package that implements the part. If the package does
not implement a part, the section names the consumer that must do it. Wave 1
(BH-5558) ships only this package. The waves after it are its consumers. They are
not behavior of this package.

The package holds pure functions only. It has no network call, no DB access, no
model call, no file write and no `node:` import. All functions are exported from
`src/index.js`.

## Soul

The soul is the identity of an agent and three lists:

- MAY: the actions the agent does without asking.
- NEVER: the actions the agent must refuse at every autonomy level.
- REPORT: the reports the agent sends.

Implementation:

- `parseSoul(md)` reads the three lists from soul markdown. It returns
  `{ may, never, report }`.
  - A label opens a block only at the start of a line: `MAY`, `NEVER` or `REPORT`,
    optional text, then `:`. A label in the middle of a line opens no block.
  - A block ends at a blank line or at the next label.
  - Prose form: items split on `,` and `;` outside parentheses. A leading `and ` or
    `or ` and a trailing `.` are removed.
  - List form: if the label line has no text after the `:` and every next line is a
    `- item` or `* item` line, each line is one item.
  - A label that occurs two times adds to the same list.
  - A non-string input throws `TypeError`.
- `validateSoul(soul)` returns `{ ok, errors }`. Each empty list gives the error
  `<LABEL> block missing or empty`.
- `schema/soul.schema.json` defines the soul front-matter block: `name`, `role`,
  `accountable`, `version`.

Example: the sorted concatenation of `prompts/archie-soul.d/*.md` gives 6 NEVER items.

## Memory

An agent has three kinds of memory:

- Episodic: what happened. `schema/finding.schema.json`, `schema/decision.schema.json`
  and `schema/outcome.schema.json` define the records.
- Semantic: what is known to be true or muted. `schema/suppression.schema.json`
  defines a mute: one fingerprint, a reason, an approver and an expiry time.
- Procedural: how to do a task. This is the consumer's job (skills and prompts).

Storage of all memory is the consumer's job. This package stores nothing.

## Heartbeat

One heartbeat has six steps:

1. Collect items. Consumer's job.
2. Fingerprint each item. `fingerprint(item)` returns a 64-character hex SHA-256 key.
3. Dedup the keys against the stored findings and suppressions. Consumer's job.
4. Make one model turn only if an item is new. Consumer's job.
5. Act by autonomy level. `decide(level, cap, action)` gives the result.
6. Record the decision and the outcome. Consumer's job. The records follow
   `schema/decision.schema.json` and `schema/outcome.schema.json`.

`fingerprint(item)`:

- A string: the key of `canonicalUrl(item)`.
- A plain object or an array: the key of a canonical JSON. The object keys are sorted
  at every depth. Each string value goes through `canonicalUrl`. A key named `token`,
  `access_token`, `auth`, `authorization`, `sig`, `signature`, `secret`, `password`,
  `key`, `api_key`, `expires` or `x-amz-*` (any case) is removed.
- `null`, `undefined`, a function, a non-finite number or another object type throws
  `TypeError`.

`canonicalUrl(s)`: an absolute `http` or `https` URL becomes scheme, lowercase host
and path. The query string, the fragment, the user info and one trailing `/` are
removed. The root path stays `/`. Any other string is returned trimmed.

The query string is removed in full, so `?page=1` and `?page=2` give the same key.

The key is a contract. A stored claim uses it. A change to the canonical form changes
every key, so a change to `fingerprint` or `canonicalUrl` must ship with a migration note.

## Autonomy

There are three levels, in this order: `automation`, `augmentation`, `autonomy`
(`LEVELS`). An agent earns a level per action class. Each class has a hard cap.

`decide(level, cap, action)`, with `action = { name, never }`, returns `allow`, `ask`
or `refuse`. The first rule that applies wins:

1. If `level` or `cap` is not in `LEVELS`, if `action.name` is not a non-empty string,
   or if `action.never` is not an array: `refuse`.
2. If `action.name` equals a NEVER entry: `refuse`. The compare ignores case,
   backticks, extra whitespace and a trailing `.`. Only a full entry matches. A
   substring does not match.
3. If `level` is above `cap`: `refuse`.
4. `automation`: `refuse` (observe only). `augmentation`: `ask`. `autonomy`: `allow`.

`nextLevel(level, history, rule)`, with `history` a list of `{ verdict }` in time
order and `rule = { agreementsToPromote, cap }`:

- If the last verdict is `overrule`: one level down. The floor is `automation`.
- If the last verdict is `delegate`, and the `rule.agreementsToPromote` verdicts
  before it are all `agree`: one level up. The level never goes above `rule.cap`.
- In all other cases the level does not change. Agreements alone never promote. A
  human must say `delegate`.
- An unknown level, a history that is not a list, or a bad rule never promotes.
  A bad rule does not stop a demotion: an overrule always demotes a known level.

`precision(outcomes)` returns `agree / (agree + overrule)`. `delegate` is not counted.
If no verdict is counted, it returns `null`, not `0`.

`schema/charter.schema.json` holds the agent's level (`autonomy`) and its `cap`.
The caller reads `agreementsToPromote` and `cap` from its own data and passes them in.

## Guardrails

- Deterministic before LLM: `decide` is a pure function. It runs before any model
  output can act.
- Output never input: `isOwnOutput(finding, agent)` is true when `finding.source.labels`
  has `staff:<agent>` or `finding.source.filedBy` is the agent. The compare is trimmed
  and lowercase. The consumer must drop such a finding. The rule for a finding from
  any staff agent is the consumer's job, wave 3.
- Dedup before spend: `fingerprint` gives the key. The claim before the model call is
  the consumer's job, wave 3.
- Context budget: consumer's job.
- Kill switch: consumer's job. `schema/charter.schema.json` has `status`
  (`active`, `paused`, `retired`) for it.
- Audit trail: `schema/decision.schema.json` and `schema/outcome.schema.json` define
  the records. Storage is the consumer's job.

## Schemas

The six schemas in `schema/` use JSON Schema 2020-12 and `additionalProperties: false`.
`validate(schema, value)` returns `{ ok, errors }`. It supports only `type`, `required`,
`properties`, `additionalProperties` (boolean), `enum`, `items`, `minLength`,
`minItems`, `minimum`, `pattern` and the annotations `$schema`, `$id`, `title`,
`description`. Any other keyword throws `unsupported keyword <k>`, so a schema is
never enforced in part without a signal.
