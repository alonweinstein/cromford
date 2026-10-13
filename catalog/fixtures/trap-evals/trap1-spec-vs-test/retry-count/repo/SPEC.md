# Retrying calls to the payments provider

`with_retry <cmd...>` in `lib/retry.sh` runs a command until it succeeds.

- A command is attempted **at most 3 times** in total (the first try plus two retries).
  The provider rate-limits clients that try more often.
- `with_retry` returns 0 as soon as one attempt succeeds, and 1 after the third failure.
