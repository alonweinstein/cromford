# Testing

How tests in this repo are written. The build rules are in
`prompts/build-discipline.md`; this file has the reasons behind the test-style rules.

## Assert the fields you own

A test asserts the fields its feature owns. It does not pin the whole payload.

Not: `jq -S .` of the whole document, `assert.deepEqual(body, {…})`, or
`eq "T6" "$(tix ghp)" '{"ready":null,"blocked":null,"held":null,…}'`.

Yes: `jq -c '[.ready, .held]'`, `assert.deepEqual(body.accounts, […])`,
`assert.equal(body.ready, 2)`.

### Why

A whole-output pin breaks the day another ticket adds a key it does not care
about. On #4126, `tests/utilization-tickets.bh-3988-test.sh` pinned whole
payloads. Main then merged BH-4010, which added `pauses` and `prs` keys to every
payload. T1, T5 and T6 went red. Each break cost a fix round and a new review,
and none of them found a defect.

### Contract tests

Sometimes the whole shape IS the feature: a public API payload, a file format
another system reads. Then pin it whole, in a contract test. A file is a
contract test when one of these is true:

- Its name matches `*.contract.test.*` (for example `api.contract.test.js`).
- A line in its first 15 lines is `# contract-test` (shell) or
  `// contract-test` (JS/TS). Text after a space or a colon is allowed:
  `// contract-test: the /v1/board payload`.

The lint skips a contract test file whole.

### The lint

`bin/test-payload-pin-lint.sh` reports a NEW whole-payload compare in a test
file. Run it before you commit:

```bash
bin/test-payload-pin-lint.sh --base origin/main .
```

- `--base <ref>` judges only the lines added since the merge-base. This is the
  default mode, and the CI step uses it.
- `--all` lists every match in every test file. Use it as an inventory.
- `--strict` makes a finding an error (rc 1).
- Test files are the `file`/`skip` lines of `catalog/determinism-lint.conf`.

It has three rules, each a `rule` line in `catalog/payload-pin-lint.conf`:

| rule | flags |
|---|---|
| `jq-sort-whole` | `jq -S .` (also `-Sc`, `-cS`) over the identity filter |
| `deep-equal-whole` | `assert.deepEqual(x, {`, `assert.deepStrictEqual(x, {`, `expect(x).toEqual({`, `expect(x).toStrictEqual({`, where `x` is a bare name, `await y.json()` or `JSON.parse(…)` |
| `json-literal-whole` | a shell assertion (`eq`, `assert*`, `[ … = … ]`, `[[ … == … ]]`) against a `'{"…"}'` literal with 3 or more keys (`opt min_keys`) |

Blind spots. The lint reads one line at a time, so it does not see:

- a whole payload that reaches the compare through a variable set on another line;
- a deep-equal whose expected value is a variable, not an object literal;
- a call split before the `{`.

### Warn mode, and how to make it a gate

The conf ships `mode warn`. A finding prints, CI shows a yellow annotation on
the line, and the exit code stays 0. The PR `lint` job runs the step
`whole-payload pin lint (BH-5792, warn only)`.

To make it a gate, set `mode error` in `catalog/payload-pin-lint.conf` and add
the lint to `catalog/rules-pack.tsv`. The rules pack reads findings only from a
red component, so a warn-mode row there would show nothing.

A box can override the conf with `$HARNESS/flags/payload-pin-lint.conf`, or a
run with `PAYLOAD_PIN_LINT_CONF=<path>`.
