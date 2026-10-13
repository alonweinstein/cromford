#!/bin/bash
# tests/review-pool-cap.bh-5337-test.sh — BH-5337: rpool_init (bin/lib/review-pool.sh)
# sizes the review pool from three box terms when P_BOX_MAX is unset: vCPU
# (ncpu / P_WORKER_CPUS), memory (MemAvailable / P_WORKER_MEM_MB, and with a
# tmpfs /tmp the tmpfs use is taken off and the per-worker scratch added on)
# and free /tmp. The smallest wins and is logged as
# `concurrency capped at N by cpu|memory|tmp (...)`.
# Seams: REVIEW_POOL_NPROC, REVIEW_POOL_MEMINFO, REVIEW_POOL_TMP_FSTYPE,
# REVIEW_POOL_TMP_PATH, and a df stub on PATH that answers size/used/free (MB)
# from $T/df.{size,used,free}.
#   C1  the 2026-10-08 incident: 4 vCPU, 11231 MB free, tmpfs 1024 MB used, K=10 -> 4 by cpu
#   C2  64 vCPU, 8192 MB, tmpfs 1024 MB used -> 3 by memory; C2b same on ext4 -> 4
#   C3  no WORKER_* knob: 4096 MB on disk -> 2 (the 2048 MB default)
#   C4  1800 MB free /tmp, 1536 floor -> 1 by tmp
#   C5  K=3 on a big box -> 3, no cap line, RPOOL_CAP_BY empty
#   C6  LEAD_REVIEW_WORKER_CPUS=2 on 4 vCPU -> 2; C6b =3 -> 1
#   C7  LEAD_REVIEW_BOX_MAX=6 on 4 vCPU -> 6 by box_max (it overrides the terms)
#   C8  nproc and getconf fail -> the CPU term is skipped, memory still caps
#   C9  MemAvailable below the tmpfs use -> K=1, never below
#   C11 K=0 (no cap) on 64 vCPU, 512 GB -> 64 by cpu
#   C12 a cpu/memory tie names cpu
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-pool-cap.bh-5337-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
DIR="$SRC"   # tests/lib/rendered.sh reads $DIR as the repo root
# catalog/lanes.json is generated and not committed: C13 renders it into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin" "$T/nocpu" "$T/tmpdir"
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
s=\$(cat "$T/df.size"); u=\$(cat "$T/df.used"); f=\$(cat "$T/df.free")
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake %s %s %s 9%% /tmp\n' "\$((s * 1024))" "\$((u * 1024))" "\$((f * 1024))"
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/nocpu/nproc"
cp "$T/nocpu/nproc" "$T/nocpu/getconf"
chmod +x "$T/fakebin/df" "$T/nocpu/nproc" "$T/nocpu/getconf"

disk() { echo "$1" > "$T/df.size"; echo "$2" > "$T/df.used"; echo "$3" > "$T/df.free"; }
mem()  { printf 'MemTotal: 16777216 kB\nMemAvailable: %s kB\n' "$1" > "$T/meminfo"; }

# pool <k> [VAR=val ...] — rpool_init in a clean shell. OUT="K|CAP_BY",
# the log lines in $T/log.
pool() {
  local k="$1"; shift
  : > "$T/log"
  OUT=$(env -u LEAD_REVIEW_BOX_MAX -u LEAD_REVIEW_WORKER_CPUS -u LEAD_REVIEW_WORKER_MEM_MB \
      -u LEAD_REVIEW_WORKER_TMP_MB -u LEAD_REVIEW_TMP_MIN_MB -u REVIEW_POOL_NPROC -u REVIEW_POOL_TMP_FSTYPE \
      PATH="$T/fakebin:$PATH" REVIEW_POOL_TMP_SWEEP='' REVIEW_POOL_MEMINFO="$T/meminfo" \
      REVIEW_POOL_TMP_PATH="$T/tmpdir" "$@" bash -c '
    . "$1"; LG="$3/log"; lg() { printf "%s\n" "$*" >> "$LG"; }
    rpool_init lead-review LEAD_REVIEW "$2" "$3/pool" lg
    printf "%s|%s" "$RPOOL_K" "$RPOOL_CAP_BY"' _ "$SRC/bin/lib/review-pool.sh" "$k" "$T" 2>&1)
}
logged() { grep -qF "$1" "$T/log"; }

# ── C1: the incident ──
mem 11500544; disk 12288 1024 11264
pool 10 REVIEW_POOL_NPROC=4 REVIEW_POOL_TMP_FSTYPE=tmpfs
[ "$OUT" = "4|cpu" ] && ok || bad "C1 want '4|cpu', got '$OUT' (log: $(cat "$T/log"))"
logged 'concurrency capped at 4 by cpu (4 vCPU, 1 a worker)' && ok || bad "C1 cap line: $(cat "$T/log")"

# ── C2: tmpfs use comes off free memory, the scratch reserve goes on a worker ──
mem 8388608; disk 12288 1024 11264
pool 10 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=tmpfs
[ "$OUT" = "3|memory" ] && ok || bad "C2 want '3|memory', got '$OUT' (log: $(cat "$T/log"))"
logged "concurrency capped at 3 by memory (8192MB free, 1024MB in tmpfs $T/tmpdir, 2048+256MB a worker)" && ok || bad "C2 cap line: $(cat "$T/log")"
pool 10 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=ext4
[ "$OUT" = "4|memory" ] && ok || bad "C2b want '4|memory', got '$OUT'"
logged 'concurrency capped at 4 by memory (8192MB free, 2048MB a worker)' && ok || bad "C2b cap line: $(cat "$T/log")"

# ── C3: the 2048 MB default ──
mem 4194304; disk 204800 0 102400
pool 10 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=disk
[ "$OUT" = "2|memory" ] && ok || bad "C3 want '2|memory', got '$OUT'"
logged '2048MB a worker' && ok || bad "C3 cap line: $(cat "$T/log")"

# ── C4: free /tmp ──
mem 67108864; disk 2048 248 1800
pool 10 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=disk
[ "$OUT" = "1|tmp" ] && ok || bad "C4 want '1|tmp', got '$OUT'"
logged "concurrency capped at 1 by tmp ($T/tmpdir 1800MB free, 1536MB floor, 256MB a worker)" && ok || bad "C4 cap line: $(cat "$T/log")"

# ── C5: nothing caps ──
mem 67108864; disk 204800 0 102400
pool 3 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=disk
[ "$OUT" = "3|" ] && ok || bad "C5 want '3|', got '$OUT'"
[ -s "$T/log" ] && bad "C5 a cap line with nothing capping: $(cat "$T/log")" || ok

# ── C6: the WORKER_CPUS knob ──
pool 10 REVIEW_POOL_NPROC=4 REVIEW_POOL_TMP_FSTYPE=disk LEAD_REVIEW_WORKER_CPUS=2
[ "$OUT" = "2|cpu" ] && ok || bad "C6 want '2|cpu', got '$OUT'"
logged 'concurrency capped at 2 by cpu (4 vCPU, 2 a worker)' && ok || bad "C6 cap line: $(cat "$T/log")"
pool 10 REVIEW_POOL_NPROC=4 REVIEW_POOL_TMP_FSTYPE=disk LEAD_REVIEW_WORKER_CPUS=3
[ "$OUT" = "1|cpu" ] && ok || bad "C6b want '1|cpu', got '$OUT'"

# ── C7: BOX_MAX overrides all three terms ──
pool 10 REVIEW_POOL_NPROC=4 REVIEW_POOL_TMP_FSTYPE=disk LEAD_REVIEW_BOX_MAX=6
[ "$OUT" = "6|box_max" ] && ok || bad "C7 want '6|box_max', got '$OUT'"
logged 'concurrency capped at 6 by LEAD_REVIEW_BOX_MAX=6' && ok || bad "C7 cap line: $(cat "$T/log")"

# ── C8: an unreadable CPU count skips that term only ──
mem 4194304
pool 10 PATH="$T/nocpu:$T/fakebin:$PATH" REVIEW_POOL_TMP_FSTYPE=disk
[ "$OUT" = "2|memory" ] && ok || bad "C8 want '2|memory', got '$OUT'"
logged 'vCPU' && bad "C8 a CPU reason with no CPU count: $(cat "$T/log")" || ok

# ── C9: never below 1 ──
mem 524288; disk 12288 2048 10240
pool 10 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=tmpfs
[ "$OUT" = "1|memory" ] && ok || bad "C9 want '1|memory', got '$OUT'"

# ── C11: K=0 is bounded by the vCPU count (512 GB: memory allows 256) ──
mem 536870912; disk 204800 0 102400
pool 0 REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=disk
[ "$OUT" = "64|cpu" ] && ok || bad "C11 want '64|cpu', got '$OUT'"

# ── C12: a tie between cpu and memory names cpu ──
mem 8388608
pool 10 REVIEW_POOL_NPROC=4 REVIEW_POOL_TMP_FSTYPE=disk
[ "$OUT" = "4|cpu" ] && ok || bad "C12 want '4|cpu', got '$OUT'"

# ── C13: the lead-review lane's measured default reaches the pool ──────────────
# LEAD_REVIEW_WORKER_MEM_MB is a required knob (default 700 = the 545 MB peak
# measured on box-small + 25%), so lane_env_apply exports it when no
# settings row is set; the 2048 in review-pool.sh is only the no-registry fallback.
# The registry is RENDERED into the copy (lead review lr-6099 of 1c7aaaf5f): a
# clean checkout has no catalog/lanes.json, and without it lane_env_apply
# exports nothing, so the case passed only where somebody had rendered.
REG13=$(rendered_registry) || REG13=""
C13=$( [ -s "$REG13" ] || exit 9
  mkdir -p "$T/c13/state" "$T/c13/logs" && cp -r "$SRC/catalog" "$T/c13/" && cp "$REG13" "$T/c13/catalog/lanes.json" || exit 9
  # A fresh bash: no lane-gate cache from the cases above leaks in.
  HARNESS="$T/c13" LIB="$SRC/bin/lib/lane-gate.sh" bash -c '
    unset LEAD_REVIEW_WORKER_MEM_MB JOBS_URL HARNESS_SECRET LANE_REGISTRY
    . "$LIB" >/dev/null 2>&1 || exit 9
    lane_env_apply lead-review >/dev/null 2>&1
    printf "%s" "${LEAD_REVIEW_WORKER_MEM_MB:-unset}"' )
[ "$C13" = 700 ] && ok || bad "C13 lane_env_apply lead-review: LEAD_REVIEW_WORKER_MEM_MB='$C13', want 700"

echo "review-pool-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
