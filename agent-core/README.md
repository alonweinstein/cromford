# @example-org/agent-core

Pure functions and JSON Schemas for an always-on staff agent. `SPEC.md` defines
the agent anatomy and maps each part to the code here.

License: Apache-2.0. Each source file has an SPDX header.

No network, no DB, no model call. The package has no dependencies and no `node:`
import in `src/`. It uses only the globals `URL` and `TextEncoder`. Node 22 and
Cloudflare Workers both have them. The tests run on Node 22.

## Test

```bash
cd agent-core && npm test
```

CI runs it through `tests/agent-core.bh-5558-test.sh`.

## Functions

| Function | File | Returns |
|---|---|---|
| `parseSoul(md)` | `src/soul.js` | `{ may, never, report }` string lists |
| `validateSoul(soul)` | `src/soul.js` | `{ ok, errors }`; each empty list is an error |
| `LEVELS` | `src/autonomy.js` | `['automation', 'augmentation', 'autonomy']` |
| `decide(level, cap, action)` | `src/autonomy.js` | `'allow'`, `'ask'` or `'refuse'` |
| `nextLevel(level, history, rule)` | `src/autonomy.js` | the next level |
| `fingerprint(item)` | `src/fingerprint.js` | 64 lowercase hex characters |
| `canonicalUrl(s)` | `src/fingerprint.js` | the URL without query, fragment and user info |
| `sha256(str)` | `src/sha256.js` | SHA-256 hex of the UTF-8 bytes |
| `isOwnOutput(finding, agent)` | `src/learning.js` | `true` when the agent made the finding |
| `precision(outcomes)` | `src/learning.js` | `agree / (agree + overrule)`, or `null` |
| `validate(schema, value)` | `src/validate.js` | `{ ok, errors }`; an unsupported keyword throws |

## Schemas

`schema/charter.schema.json`, `soul.schema.json`, `finding.schema.json`,
`suppression.schema.json`, `decision.schema.json`, `outcome.schema.json`.
Each has a valid example in `test/fixtures/`.
