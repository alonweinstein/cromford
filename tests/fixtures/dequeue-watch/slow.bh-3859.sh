#!/bin/bash
# shellcheck shell=bash
# tests/fixtures/dequeue-watch/slow.bh-3859.sh — BH-3859: the shared dequeue-watch
# fixture with a tick that never finishes in time. mc_queue_provider sleeps, so
# a lane run under DEQUEUE_WATCH_TICK_TIMEOUT_S=1 is killed by its own timeout
# wrapper (tests/dequeue-watch-ship-dark.bh-3859-test.sh T1).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixture.sh"
mc_queue_provider() { sleep 5; printf 'mergify'; }
