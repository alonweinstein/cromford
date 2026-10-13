# Billing

FIXTURE entry.

**What it is:** the invoice list and its detail view.

**How a user reaches it:** sign in → sidebar → Billing.

**Key routes/screens:** `/billing` (list), `/billing/[id]` (detail).

**Selectors:** `role=table[name="Invoices"]`, `data-testid=invoice-row`.

**Preconditions:** at least one seeded invoice for the QA user.

**Manual-only:** the Stripe redirect leaves the app — not automatable here.

**What usually lies:**
- the invoice total renders before the Stripe webhook settles it
