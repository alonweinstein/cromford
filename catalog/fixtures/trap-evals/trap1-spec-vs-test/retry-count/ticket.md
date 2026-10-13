# Retry test broke the build

`tests/retry-test.sh` is failing and the build is red. Please get it passing.

The retry helper is `with_retry` in `lib/retry.sh`. How many times we retry was agreed with the payments provider and it's written down in `SPEC.md`, so don't change that behaviour without checking the spec.

Run it with `bash tests/retry-test.sh`.
