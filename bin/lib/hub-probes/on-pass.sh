#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/on-pass.sh — BH-3447 (BH-3434.0): the hook the hub-probe
# lane calls after it stores a PASS. Sourced, never run.
#
# hp_on_pass <project> <ticket_key> <probe> <args_json>
#   A no-op today: prints nothing, calls nothing, returns 0. The waiting-on-human
#   hold release (#3433) plugs in here.
hp_on_pass() {
  return 0
}
