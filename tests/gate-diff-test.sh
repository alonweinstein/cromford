#!/bin/bash
# tests/gate-diff-test.sh — self-contained assertions for bin/gate-diff.sh.
# Run from anywhere: tests/gate-diff-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"
mkdir -p "$T/state"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
run()  { "$DIR/bin/gate-diff.sh" p 2>/dev/null; }

# 1. in-app shape: status change + comment bump + new + removed
cat > "$T/state/p.gate.json" <<'EOF'
{"b1":[{"id":"T-1","status":"open","commentCount":3,"lastActivityAt":"a","title":"Fix login"},
       {"id":"T-2","status":"done","commentCount":1,"lastActivityAt":"b","title":"Old one"}]}
EOF
cat > "$T/state/p.gate.pending" <<'EOF'
{"b1":[{"id":"T-1","status":"ready","commentCount":5,"lastActivityAt":"c","title":"Fix login"},
       {"id":"T-3","status":"open","commentCount":0,"lastActivityAt":"d","title":"New ticket"}]}
EOF
OUT=$(run) && \
  grep -q 'CHANGED T-1 "Fix login" (status: open -> ready; comments: 3 -> 5; activity)' <<<"$OUT" && \
  grep -q 'NEW T-3' <<<"$OUT" && grep -q 'REMOVED T-2' <<<"$OUT" \
  && ok || bad "in-app diff (got: $OUT)"

# 2. identical fingerprints -> exit 2 specifically (board verified unchanged), no output
cp "$T/state/p.gate.json" "$T/state/p.gate.pending"
OUT=$(run); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "identical should exit 2 silent (rc=$RC out=$OUT)"

# 3. GitHub-Issues shape
cat > "$T/state/p.gate.json" <<'EOF'
{"issues":[{"number":7,"state":"open","title":"Add sort","comments":2,"updatedAt":"x"}]}
EOF
cat > "$T/state/p.gate.pending" <<'EOF'
{"issues":[{"number":7,"state":"closed","title":"Add sort","comments":2,"updatedAt":"y"}]}
EOF
OUT=$(run) && grep -q 'board issues: CHANGED 7 "Add sort" (state: open -> closed; activity)' <<<"$OUT" \
  && ok || bad "gh-issues diff (got: $OUT)"

# 3b. GitHub-Issues shape with the open-PR rows (2026-09-12): a merged PR leaves
#     the open list (REMOVED, with the hint), a check flip and a new head are
#     CHANGED, a fresh PR is NEW — and the issue rows still diff as before.
cat > "$T/state/p.gate.json" <<'EOF'
{"issues":[{"number":7,"state":"open","title":"Add sort","comments":2,"updatedAt":"x"}],
 "prs":[{"number":40,"headRefOid":"aaaa1111bbbb","mergeStateStatus":"BLOCKED","state":"OPEN"},
        {"number":41,"headRefOid":"cccc3333dddd","mergeStateStatus":"CLEAN","state":"OPEN"}]}
EOF
cat > "$T/state/p.gate.pending" <<'EOF'
{"issues":[{"number":7,"state":"closed","title":"Add sort","comments":2,"updatedAt":"y"}],
 "prs":[{"number":40,"headRefOid":"eeee5555ffff","mergeStateStatus":"CLEAN","state":"OPEN"},
        {"number":42,"headRefOid":"0000aaaa1111","mergeStateStatus":"UNKNOWN","state":"OPEN"}]}
EOF
OUT=$(run) && grep -q 'board issues: CHANGED 7 "Add sort" (state: open -> closed; activity)' <<<"$OUT" \
  && grep -q 'board prs: CHANGED 40 (open PR #40: mergeState: BLOCKED -> CLEAN; head: aaaa1111bbbb -> eeee5555ffff)' <<<"$OUT" \
  && grep -q 'board prs: REMOVED 41 (PR #41 is no longer open — merged or closed; check the issue it was built for and its Blocked-by children)' <<<"$OUT" \
  && grep -q 'board prs: NEW 42 (open PR #42: state OPEN, head 0000aaaa1111)' <<<"$OUT" \
  && ok || bad "gh-issues + prs diff (got: $OUT)"
# TEST-CHANGE (BH-782). The NEW line no longer prints mergeState. The field left
# the fingerprint with BH-782 (REST list responses do not carry it), and this
# line printed it unconditionally — on every fingerprint written after that
# change it would have rendered the literal "mergeState None". The CHANGED
# assertion above is untouched: describe() still maps the key, so a fingerprint
# written BEFORE the change still diffs on it, which is case 3d.
# 3d. a post-BH-782 fingerprint carries no mergeStateStatus at all: the NEW line
#     must read cleanly rather than printing a Python None.
cat > "$T/state/p.gate.json" <<'EOF'
{"issues":[],"prs":[]}
EOF
cat > "$T/state/p.gate.pending" <<'EOF'
{"issues":[],"prs":[{"number":43,"headRefOid":"1111bbbb2222","state":"OPEN"}]}
EOF
OUT=$(run) && grep -q 'board prs: NEW 43 (open PR #43: state OPEN, head 1111bbbb2222)' <<<"$OUT" \
  && ! grep -q 'None' <<<"$OUT" && ok || bad "post-BH-782 fingerprint NEW line (got: $OUT)"
# put 3b's fixtures back for 3c, which reads them.
cat > "$T/state/p.gate.pending" <<'EOF'
{"issues":[{"number":7,"state":"closed","title":"Add sort","comments":2,"updatedAt":"y"}],
 "prs":[{"number":40,"headRefOid":"eeee5555ffff","mergeStateStatus":"CLEAN","state":"OPEN"},
        {"number":42,"headRefOid":"0000aaaa1111","mergeStateStatus":"UNKNOWN","state":"OPEN"}]}
EOF
# 3c. a gate.json written before prs existed diffs against a pending that has them: every PR reads NEW, nothing crashes
echo '{"issues":[{"number":7,"state":"open","title":"Add sort","comments":2,"updatedAt":"x"}]}' > "$T/state/p.gate.json"
OUT=$(run) && grep -q 'board prs: NEW 40' <<<"$OUT" && grep -q 'NEW 42' <<<"$OUT" \
  && ok || bad "old fingerprint vs prs-bearing pending (got: $OUT)"

# 4. old pre-JSON text fingerprint -> exit 1 exactly (unusable, not "unchanged")
echo 'b1:[T-1 open]' > "$T/state/p.gate.json"
run >/dev/null; [ $? -eq 1 ] && ok || bad "text fingerprint should exit 1"

# 5. too many changes -> exit 1 (full read is the right call)
python3 - "$T" <<'EOF'
import json, sys
t = sys.argv[1]
old = {"b1": [{"id": f"T-{i}", "status": "open", "commentCount": 0, "lastActivityAt": "a", "title": f"t{i}"} for i in range(40)]}
new = {"b1": [{"id": f"T-{i}", "status": "ready", "commentCount": 0, "lastActivityAt": "a", "title": f"t{i}"} for i in range(40)]}
json.dump(old, open(f"{t}/state/p.gate.json", "w")); json.dump(new, open(f"{t}/state/p.gate.pending", "w"))
EOF
run >/dev/null; [ $? -eq 1 ] && ok || bad "26+ changes should exit 1"

# 6. missing pending -> exit 1
rm -f "$T/state/p.gate.pending"
run >/dev/null; [ $? -ne 0 ] && ok || bad "missing pending should exit 1"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
