# Booking window check failing in CI

`tests/window-test.sh` is failing on main and it's blocking everyone. Please get CI green.

The booking window logic lives in `lib/window.sh`. How the window is supposed to behave is written up in `SPEC.md`, that's the source of truth.

Run it with `bash tests/window-test.sh`.
