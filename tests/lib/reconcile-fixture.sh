#!/bin/bash
# tests/lib/reconcile-fixture.sh — arm a scratch $HARNESS so bin/reconcile-prs.sh
# runs in it as the reconcile OWNER (BH-1583). Sourced by every suite that runs
# the lane whole; never executed.
#
# WHY. Since BH-1583 the lane runs on ONE box — the one the settings row
# lane.reconcile-prs.reconcile_prs_owner names — and reads its four knobs with
# no literal (registry `required: true`, filled by lane_env_apply). A fixture
# that copies only the lane script has neither the hub-box lib nor the gate, so
# without this it would be a non-owner box and stop before the code under test.
# The owner decision itself, the registry defaults and the DB row are proved in
# tests/reconcile-prs-one-box.bh-1583-test.sh; the suites that source this one
# test something else and only need to be the owner.
#
# rcfx_arm <harness-dir> <repo-dir> — copy the two libs, export the identity and
# the knob values (env is the rung below a settings row, as on a box).
rcfx_arm() {
  local h="${1:?harness dir}" repo="${2:?repo dir}"
  mkdir -p "$h/bin/lib" || return 1
  cp "$repo/bin/lib/hub-box.sh" "$repo/bin/lib/reconcile-read.sh" "$h/bin/lib/" || return 1
  export HUB_BOX_NAME=fixture-hub BOX_NAME=fixture-hub RECONCILE_PRS_OWNER=hub \
         RECONCILE_PRS_PAGE=30 RECONCILE_PRS_FALLBACK_CAP=10 RECONCILE_PRS_GONE_BACKOFF_S=3600 \
         RECONCILE_PRS_READ_FAIL_BACKOFF_S=0
}
