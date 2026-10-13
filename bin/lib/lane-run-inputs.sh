# shellcheck shell=bash
# bin/lib/lane-run-inputs.sh — SEAM (BH-6124 creates it, BH-6047 part 5
# fills it): the inputs a lane reads from the hub, fetched onto the machine
# before the run starts.
#
#   lri_fetch <lane> <project> <dir>  rc 0 = the inputs are in <dir>; any other
#                                     rc and bin/lane-run-worker.sh skips the run
#
# Defines functions only. Nothing runs on source. A stub until part 5.
lri_fetch() { return 0; }
