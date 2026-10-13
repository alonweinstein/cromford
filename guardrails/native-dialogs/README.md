# Guardrail: native browser dialogs

**Iron law:** never use `window.confirm()` / `window.alert()` / `window.prompt()`
for confirmations, alerts, or questions in any web app. They are off-brand,
inaccessible, and they freeze browser automation — a Chrome MCP or QA agent
hangs on a native dialog until a human dismisses it, which is how a QA run
"times out" for reasons nobody can see in the logs.

**What it catches:** `window.*` and `globalThis.*` forms of confirm / alert /
prompt in app code.

**Tool:** semgrep. `rule.yml` is a complete config.

```bash
semgrep scan --config rule.yml --error <path>
```

**Applicability:** any repo with a browser UI. Not applicable to pure-backend
repos or the harness itself.

**Deliberately NOT matched: the bare `confirm(...)` / `alert(...)` form.** A
pattern that broad flags every project-local helper named `confirm` — and a
check that cries wolf gets skipped, then deleted. `window.`/`globalThis.` is the
form that actually reaches the browser API, and it is the form the codemod
leaves behind. A project that calls the bare global can add the bare patterns to
its own copy of this rule.

**Escape hatch:** `skip-guardrail` label + `GUARDRAIL_JUSTIFICATION` (see
`../README.md`).
