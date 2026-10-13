# Add your own machine

A machine outside the build pool can take part in the harness as a
*participant*: it asks for a row, someone holding the lead token approves it,
and from then on it calls the jobs worker with its own credential. Revoking it
stops it on its next call. This page is the whole loop, using
`bin/machine-enroll.sh`.

The examples use placeholders: `my-laptop` for the machine name,
`owner@example.com` for the owner, `https://jobs.example.com` for the worker
and `<id>` for the participant id `request` prints.

## What you need

- A checkout of this repo on the machine, plus `jq`, `curl`, and either
  `openssl` or `/dev/urandom`.
- `JOBS_URL` and `HARNESS_SECRET`, in the environment or in `env/global.env`.
  Every `/api` route on the worker checks the bearer first, so a participant
  needs it too:

  ```bash
  export JOBS_URL=https://jobs.example.com
  export HARNESS_SECRET=...   # from whoever runs the harness
  ```

## Request

On the machine you're adding:

```bash
bin/machine-enroll.sh request my-laptop --roles lead-review --owner owner@example.com
```

It prints `pending <id> my-laptop`. Here's what happened:

- 32 random bytes were written as 64 hex characters to
  `~/.config/cromford/participant-token`, mode 600. Set
  `HARNESS_PARTICIPANT_TOKEN_FILE` to put it somewhere else.
- Only the token's sha256 went to the worker, with the name, roles and owner.
  The token itself is never on a command line and never printed.
- If the worker refused (name taken, bad role, unreachable), the token file is
  deleted and the command exits 1 with the worker's reason. Nothing is left
  behind pointing at no row.
- If a token file is already there, `request` refuses and touches nothing. That
  file may be a live credential: revoke it first, then delete it.

`--billing-account x` is optional. Names are lowercased and trimmed by the
worker, and the output shows the name it stored.

Check where it stands at any time:

```bash
bin/machine-enroll.sh status
```

It prints `pending` (exit 3) until someone approves it.

## Approve

Whoever holds the lead token (`LEAD_VERDICT_TOKEN_FILE`, default
`~/.config/cromford/lead-verdict-token`) approves from their own machine,
with the id from the request:

```bash
bin/machine-enroll.sh approve <id> --roles lead-review --by your-name
```

`--roles` is what's granted, and it has to be a subset of what was requested.
To turn a request down instead, use `bin/machine-enroll.sh deny <id>`. The lead
token reaches the worker in a 0600 header file, never on the command line.

Back on the new machine, `status` now says so:

```bash
bin/machine-enroll.sh status
```

It prints `approved <id> my-laptop roles=lead-review` and exits 0.

## Run

The plan is for the machine to claim lead reviews with:

```bash
HARNESS_PARTICIPANT_TOKEN_FILE=~/.config/cromford/participant-token bin/lead-review.sh tick
```

That doesn't work yet. `bin/lead-review.sh` doesn't read
`HARNESS_PARTICIPANT_TOKEN_FILE` until BH-5348.2 (#5351) lands. Until then an
enrolled machine can request and check its status, but it can't claim reviews.

## Revoke

```bash
bin/machine-enroll.sh revoke <id>
```

The worker reads the participant row on every call, so the machine is cut off
on its next request. Then delete the token file on that machine:

```bash
rm ~/.config/cromford/participant-token
```

A name stays taken after a revoke. To enroll the machine again, send a new
`request` under a new name.

## Exit codes

| Command | 0 | 1 | 3 |
|---|---|---|---|
| `request` | pending row created | refused or unreachable (token file removed) | |
| `status` | approved | error, unknown token, unreachable | pending, denied or revoked |
| `approve`, `deny`, `revoke` | done (or already done: `(unchanged)`) | refused or unreachable | |
