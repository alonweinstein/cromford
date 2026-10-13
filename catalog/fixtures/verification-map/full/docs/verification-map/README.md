# Verification map — demo-os

FIXTURE. Stands in for a repo that has adopted the map.

Index of every user-facing feature and how to reach and drive it.

| feature | entry | primary route |
|---|---|---|
| Billing | [billing.md](billing.md) | `/billing` |
| Client intake | [client-intake.md](client-intake.md) | `/clients/new` |

## Driving conventions

- Selectors: prefer ARIA roles and `data-testid`; never a Tailwind class chain.
- Waiting: poll an observable end-state (a row appears, a toast's text) — never `sleep`.
- `page.evaluate` reads state only; it never invokes a handler the user would click.
- Entitlements the QA role does not have are declared here, not silently skipped.
