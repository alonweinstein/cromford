#!/bin/bash
# bin/audit-tail.sh — read the kernel audit trail and page once per deletion burst.
#
#   audit-tail.sh --parse [--claims <dir>] [--builds <dir>] [--worktrees <dir>]
#                         [--roots "<r1> <r2>"]   < ausearch-i-output
#       PURE. stdin -> burst lines on stdout. Touches no file, opens no lock,
#       reads no env file. This is the mode the tests drive.
#
#   audit-tail.sh
#       LIVE. The cron entry point (*/5 on every box).
#
# WHY IT EXISTS (incident #388, hub wipe 2026-09-15). A test that had never
# sourced the scratch library re-derived its harness root as the LIVE one and
# deleted it. Nothing recorded who did it, from which working directory, or
# under which build — the box simply had no harness any more. auditd now watches
# the harness roots (the sibling installer slice writes the rules with key
# `harness`); this script is the reader. One line per burst into
# logs/audit-tail.log, and one alert through bin/lane-alert.sh so a wipe is
# something a person hears about inside five minutes.
#
# WHAT A BURST IS. Events with the same (pid, comm, class) collapse into ONE
# line: `rm -rf` of a tree is thousands of unlink events and exactly one thing
# that happened. class is delete / rename / truncate; every other syscall is
# dropped, and so is anything outside the watched roots.
#
# THE LANE DOES NOT WATCH ITSELF. Events under <root>/locks, <root>/state/alerts
# and <root>/state/audit-tail.checkpoint* are this script and bin/lane-alert.sh
# doing their own jobs; they are dropped before they become a burst, and the
# per-tick cap is spent critical-first, so the harness watching itself can never
# crowd out a real wipe.
#
# SEVERITY. critical when the burst touched a protected prefix (<root>/env,
# /bin, /prompts, /cron, /fleet.conf, plus /root/.ssh, /root/orchestrator/bin,
# /etc/harness), or removed a directory, or is at least AUDIT_PAGE_MIN events.
# Otherwise info. AUDIT_PAGE_ALL=1 makes everything critical. A build deleting
# its own claim file leaves a line and pages nobody.
#
# KNOBS (env/global.env): AUDIT_ROOTS, AUDIT_MAX_BURSTS_PER_TICK, AUDIT_PAGE_MIN,
# AUDIT_PAGE_ALL. Kill: AUDIT_TAIL=0, or the settings row switch.audit-off[.<box>]
# (flags/audit-off when no row). Docs: docs/AUDIT-TRAIL.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-audit-tail
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off audit-tail.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# shellcheck source=lib/lane-switch.sh
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file, as before
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit audit-tail
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    audit-tail

MODE=live
OPT_CLAIMS=""; OPT_BUILDS=""; OPT_WT=""; OPT_ROOTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --parse)     MODE=parse; shift ;;
    --claims)    OPT_CLAIMS="${2:-}"; shift 2 ;;
    --builds)    OPT_BUILDS="${2:-}"; shift 2 ;;
    --worktrees) OPT_WT="${2:-}"; shift 2 ;;
    --roots)     OPT_ROOTS="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *)           echo "audit-tail.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# The live entry point takes its knobs from the box's env file; --parse takes
# them from the process environment only, so it can never be changed by a file.
if [ "$MODE" = live ]; then
  . "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
  if [ -f "$HENV/global.env" ]; then
    set -a; # shellcheck disable=SC1090,SC1091
    . "$HENV/global.env"; set +a
  fi
fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    audit-tail

CLAIMS="${OPT_CLAIMS:-$H/state/claims}"
BUILDS="${OPT_BUILDS:-$H/builds}"
WT="${OPT_WT:-${WORKTREES:-/root/worktrees}}"
ROOTS="${OPT_ROOTS:-${AUDIT_ROOTS:-/root/harness /root/orchestrator /etc/harness /root/.ssh}}"
# A root is matched as "the path itself, or the path plus a slash", so a root
# written as `/root/harness/` would match nothing at all while the installer
# happily watches it — a silently blind tailer. Normalise once, here, so the
# parser and the severity rules both see what the installer installed.
if [ -n "$ROOTS" ]; then
  read -ra _RR <<< "$ROOTS"
  _RN=""
  for _R in "${_RR[@]}"; do
    while [ "${_R%/}" != "$_R" ] && [ -n "${_R%/}" ]; do _R="${_R%/}"; done
    _RN="$_RN $_R"
  done
  ROOTS="${_RN# }"
fi
CAP="${AUDIT_MAX_BURSTS_PER_TICK:-5}"
LOG="$H/logs/audit-tail.log"
ALERTS="$H/logs/ALERTS.log"
CK="$H/state/audit-tail.checkpoint"

STAMP() { date -u '+%F %TZ'; }
say() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }

# The two lists awk is not allowed to go and find for itself: awk never calls
# system() on a string that came out of the audit log, so the shell enumerates
# what exists and hands it over.
claims_list() {
  [ -d "$CLAIMS" ] || return 0
  find "$CLAIMS" -mindepth 2 -maxdepth 2 -type f 2>/dev/null | LC_ALL=C sort
}
builds_list() {
  [ -d "$BUILDS" ] || return 0
  local d
  for d in "$BUILDS"/*/; do
    [ -f "$d/pipeline.log" ] && printf '%s\n' "${d%/}"
  done
}

# ── the parser ───────────────────────────────────────────────────────────────
# One awk program, fed `ausearch -i` output on stdin. Pure: every input it needs
# beyond stdin arrives through -v. Timestamps are carried as strings and never
# parsed — the interpreted format is locale dependent, and a burst line that
# re-renders a date is a burst line that lies on a box with a different locale.
parse_bursts() {
  awk -v roots="$ROOTS" -v claimsdir="$CLAIMS" -v buildsdir="$BUILDS" -v wtdir="$WT" \
      -v claims_list="$(claims_list)" -v builds_list="$(builds_list)" \
      -v page_min="${AUDIT_PAGE_MIN:-25}" -v page_all="${AUDIT_PAGE_ALL:-0}" '
function under(p, pre) { return (p == pre || index(p, pre "/") == 1) }
function enc(v) { gsub(/[ \t]/, "%20", v); return v }
function dash(v) { return (v == "" ? "-" : v) }

# The value of `k=` on a record, read up to the next space.
function kv(s, k,   t, p, v, q) {
  t = " " s
  p = index(t, " " k "=")
  if (p == 0) return ""
  v = substr(t, p + length(k) + 2)
  q = index(v, " ")
  if (q > 0) v = substr(v, 1, q - 1)
  gsub(/"/, "", v)
  return v
}

# PATH records carry a name that may contain spaces, so it is read up to the
# ` inode=` that always follows it rather than to the next space.
function pathname(s,   t, p, v, q) {
  t = " " s
  p = index(t, " name=")
  if (p == 0) return ""
  v = substr(t, p + 6)
  q = index(v, " inode=")
  if (q > 0) v = substr(v, 1, q - 1)
  else { q = index(v, " "); if (q > 0) v = substr(v, 1, q - 1) }
  gsub(/"/, "", v)
  return v
}

# The text inside msg=audit(...): <timestamp>:<serial>.
function msgid(s,   p, v, q) {
  p = index(s, "msg=audit(")
  if (p == 0) return ""
  v = substr(s, p + 10)
  q = index(v, ")")
  if (q == 0) return ""
  return substr(v, 1, q - 1)
}
function lastcolon(s,   i) {
  for (i = length(s); i > 0; i--) if (substr(s, i, 1) == ":") return i
  return 0
}

function classof(sc, flags) {
  if (sc == "unlink" || sc == "unlinkat" || sc == "rmdir") return "delete"
  if (sc == "rename" || sc == "renameat" || sc == "renameat2") return "rename"
  if (sc == "truncate" || sc == "ftruncate") return "truncate"
  if (sc == "open" || sc == "openat" || sc == "openat2")
    return (index(flags, "O_TRUNC") > 0 ? "truncate" : "")
  return ""
}

function isprot(p,   i, n, R) {
  n = split(roots, R, /[ \t]+/)
  for (i = 1; i <= n; i++) {
    if (R[i] == "") continue
    if (under(p, R[i] "/env") || under(p, R[i] "/bin") || under(p, R[i] "/prompts") ||
        under(p, R[i] "/cron") || under(p, R[i] "/fleet.conf")) return 1
  }
  if (under(p, "/root/.ssh") || under(p, "/root/orchestrator/bin") || under(p, "/etc/harness")) return 1
  return 0
}

# THE LANE DOES NOT WATCH ITSELF. Its own churn is not an incident, and counting
# it is what makes the lane useless. Every tick this script opens the lock file
# <root>/locks/audit-tail.lock with O_TRUNC, copies and rewrites the checkpoint
# <root>/state/audit-tail.checkpoint, and bin/lane-alert.sh renames a fresh
# state file into <root>/state/alerts for every alert it is handed — plus the
# ~50 other bin/*.sh that hold a lock under <root>/locks. Each of those is a new pid, so a new burst, so a new --id that
# never dedupes. Left in, they fill AUDIT_MAX_BURSTS_PER_TICK with the harness
# watching itself and a real wipe lands in the "+N more bursts" line instead of
# on an on-call phone. Dropped here, by path, before the burst is ever counted.
function selfnoise(p, root) {
  if (under(p, root "/locks")) return 1
  if (under(p, root "/state/alerts")) return 1
  if (index(p, root "/state/audit-tail.checkpoint") == 1) return 1
  return 0
}

# A (project, KEY) pair is only a lane if the claim file or the build directory
# is really there. Nothing here guesses: an unrecognised worktree stays
# unresolved and says so.
function try(project, key,   cp, i, base) {
  cp = claimsdir "/" project "/" key
  if (cp in CLAIMSET) { LANE = "build:" project "/" key; CLAIMP = cp; SESSP = ""; return 1 }
  for (i = 1; i <= nbuilds; i++) {
    base = BUILDS_[i]
    sub(/^.*\//, "", base)
    if (index(base, project "-" key "-") == 1 && base ~ ("^" project "-" key "-[0-9]+$")) {
      LANE = "build:" project "/" key; CLAIMP = ""; SESSP = BUILDS_[i] "/pipeline.log"; return 1
    }
  }
  return 0
}

# Walk the components of a path. A component under a worktrees directory shaped
# <project>-<key-lower> (bh-405), or under a builds directory shaped
# <project>-<KEY>-<digits>, names a build. The project half contains dashes of
# its own, so the split is made by the shape of the KEY, never by the first dash.
function resolve(s,   i, n, C, comp, prefix, project, key, rest) {
  if (s == "" || s == "(null)") return 0
  n = split(s, C, "/")
  prefix = ""
  for (i = 1; i <= n; i++) {
    comp = C[i]
    if (i > 1 && comp != "") {
      if ((prefix == wtdir || prefix ~ /\/worktrees$/) && match(comp, /-[a-z][a-z0-9]*-[0-9]+$/)) {
        project = substr(comp, 1, RSTART - 1)
        key = toupper(substr(comp, RSTART + 1))
        if (try(project, key)) return 1
      }
      if ((prefix == buildsdir || prefix ~ /\/builds$/) && match(comp, /-[A-Z][A-Z0-9]*-[0-9]+-[0-9]+$/)) {
        project = substr(comp, 1, RSTART - 1)
        rest = substr(comp, RSTART + 1)
        sub(/-[0-9]+$/, "", rest)
        if (try(project, rest)) return 1
      }
    }
    prefix = (i == 1 ? C[1] : prefix "/" C[i])
  }
  return 0
}

function reset() {
  have = 0; sysc = ""; aflags = ""; pid = ""; ppid = ""; comm = ""; exe = ""
  auid = ""; ses = ""; cwd = ""; ts = ""; serial = ""; npath = 0
  split("", PN); split("", PT); split("", PM)
}

# One event -> at most one contribution to one burst.
function flushev(   i, cls, chosen, mode, p, root, n, R, k, isdir) {
  if (!have) { reset(); return }
  cls = classof(sysc, aflags)
  if (cls == "") { reset(); return }

  chosen = 0
  for (i = 1; i <= npath; i++) if (PT[i] == "DELETE") { chosen = i; break }
  if (!chosen) for (i = 1; i <= npath; i++) if (PT[i] == "NORMAL") { chosen = i; break }
  if (!chosen) {
    for (i = 1; i <= npath; i++) if (PT[i] != "") { reset(); return }   # typed, but none we can name
    if (npath > 0) chosen = npath
  }
  if (!chosen) { reset(); return }

  p = PN[chosen]; mode = PM[chosen]
  if (p == "" || p == "(null)") { reset(); return }
  if (substr(p, 1, 1) != "/") {
    if (cwd == "" || cwd == "(null)") { reset(); return }     # unjoinable: never guessed
    sub(/^\.\//, "", p)
    p = cwd "/" p
  }

  root = ""
  n = split(roots, R, /[ \t]+/)
  for (i = 1; i <= n; i++) if (R[i] != "" && under(p, R[i])) { root = R[i]; break }
  if (root == "") { reset(); return }
  if (selfnoise(p, root)) { reset(); return }

  isdir = (sysc == "rmdir") || (sysc == "unlinkat" && index(aflags, "AT_REMOVEDIR") > 0) || (mode ~ /dir/)

  k = pid SUBSEP comm SUBSEP cls
  if (!(k in BN)) {
    nord++; ORD[nord] = k
    BN[k] = 0; BCLASS[k] = cls; BPATH[k] = p; BSYS[k] = sysc; BROOT[k] = root
    BPPID[k] = ppid; BEXE[k] = exe; BCWD[k] = cwd; BAUID[k] = auid; BSES[k] = ses
    BPID[k] = pid; BCOMM[k] = comm; BFIRST[k] = ts ":" serial
    BPROT[k] = 0; BDIR[k] = 0; BLANE[k] = ""; BCLAIM[k] = ""; BSESS[k] = ""
  }
  BN[k]++
  BLAST[k] = ts ":" serial
  if (isprot(p)) BPROT[k] = 1
  if (isdir) BDIR[k] = 1
  if (BLANE[k] == "") {
    LANE = ""; CLAIMP = ""; SESSP = ""
    if (resolve(cwd) || resolve(exe) || resolve(p)) {
      BLANE[k] = LANE; BCLAIM[k] = CLAIMP; BSESS[k] = SESSP
    }
  }
  reset()
}

BEGIN {
  nclaims = split(claims_list, CL, "\n")
  for (i = 1; i <= nclaims; i++) if (CL[i] != "") CLAIMSET[CL[i]] = 1
  nbuilds = 0
  n = split(builds_list, BL, "\n")
  for (i = 1; i <= n; i++) if (BL[i] != "") BUILDS_[++nbuilds] = BL[i]
  reset()
}

/^----/   { flushev(); next }
/^time->/ { flushev(); next }

{
  id = msgid($0)
  if (id != "" && ts == "") {
    c = lastcolon(id)
    if (c > 0) { ts = substr(id, 1, c - 1); serial = substr(id, c + 1); gsub(/[ \t]/, "_", ts) }
  }
  t = kv($0, "type")
  if (t == "SYSCALL") {
    have = 1
    sysc = kv($0, "syscall"); pid = kv($0, "pid"); ppid = kv($0, "ppid")
    comm = kv($0, "comm"); exe = kv($0, "exe"); auid = kv($0, "auid"); ses = kv($0, "ses")
    nf = split($0, W, /[ \t]+/)
    for (i = 1; i <= nf; i++) if (W[i] ~ /^a[0-9]+=/) aflags = aflags " " W[i]
  } else if (t == "CWD") {
    cwd = kv($0, "cwd")
  } else if (t == "PATH") {
    npath++
    PN[npath] = pathname($0); PT[npath] = kv($0, "nametype"); PM[npath] = kv($0, "mode")
  }
}

END {
  flushev()
  for (i = 1; i <= nord; i++) {
    k = ORD[i]
    sev = "info"
    if (BPROT[k] || BDIR[k] || BN[k] + 0 >= page_min + 0 || page_all == "1") sev = "critical"
    printf "AUDIT class=%s n=%d path=%s more=%d root=%s syscall=%s pid=%s ppid=%s comm=%s exe=%s cwd=%s auid=%s ses=%s lane=%s first=%s last=%s sev=%s",
      BCLASS[k], BN[k], enc(BPATH[k]), BN[k] - 1, BROOT[k], BSYS[k], dash(BPID[k]), dash(BPPID[k]),
      enc(dash(BCOMM[k])), enc(dash(BEXE[k])), enc(dash(BCWD[k])), dash(BAUID[k]), dash(BSES[k]),
      enc(BLANE[k] == "" ? "unresolved" : BLANE[k]), dash(BFIRST[k]), dash(BLAST[k]), sev
    if (BCLAIM[k] != "") printf " claim=%s", enc(BCLAIM[k])
    else if (BSESS[k] != "") printf " session=%s", enc(BSESS[k])
    printf "\n"
  }
}'
}

# ── --parse: stdin in, burst lines out, nothing else ─────────────────────────
if [ "$MODE" = parse ]; then
  parse_bursts
  exit 0
fi

# ── LIVE ─────────────────────────────────────────────────────────────────────
# Kill switches first: off must cost nothing at all, not even a log line.
[ "${AUDIT_TAIL:-1}" = 0 ] && exit 0
lane_switch audit-off file && exit 0

# Dedupe, never a queue: a tick that finds the lock held is a tick something
# else is already doing. It skips and the next one is five minutes away.
mkdir -p "$H/locks" 2>/dev/null
exec 9>"$H/locks/audit-tail.lock" || exit 0
flock -n 9 || exit 0

# A box that cannot see must not be silent, and must not page every 5 minutes.
BLIND=""
if ! command -v ausearch >/dev/null 2>&1; then
  BLIND="ausearch is not installed"
elif ! pgrep -x auditd >/dev/null 2>&1; then
  BLIND="auditd is not running"
fi
if [ -n "$BLIND" ]; then
  say "audit-tail: BLIND ($BLIND) — nothing read this tick"
  MARK="$H/state/audit-tail-blind-$(date -u +%Y%m%d)"
  if [ ! -f "$MARK" ]; then
    mkdir -p "$H/state" "$H/logs" 2>/dev/null
    # The ALERTS line goes first and the marker only once it landed. A marker
    # written ahead of the alert means a crash, or a full disk, between the two
    # silences a blind box for the rest of the UTC day, which is exactly the
    # silence this lane exists to end. This way a failure repeats the alert.
    if echo "$(STAMP) [audit-tail] audit is BLIND on this box: $BLIND. NEEDED FROM OPERATOR/OPS: run bin/audit-install.sh (or install auditd) on this box; until then deletions under the harness roots are not recorded." >> "$ALERTS"; then
      touch "$MARK" 2>/dev/null
    fi
  fi
  exit 0
fi

mkdir -p "$H/state" "$H/logs" 2>/dev/null
FIRST_RUN=1
if [ -f "$CK" ]; then FIRST_RUN=0; cp -f "$CK" "$CK.prev" 2>/dev/null; fi
TMP=$(mktemp) || exit 0
ERR=$(mktemp) || exit 0
trap 'rm -f "$TMP" "$ERR"' EXIT

# The first run on a box has no checkpoint, and the audit log may hold days.
# `-ts recent` bounds that first tick to the last ten minutes instead of paging
# for a burst that happened before this script existed.
read_audit() { # read_audit <extra args...>
  ausearch -k harness -i --checkpoint "$CK" "$@" > "$TMP" 2> "$ERR"
}
if [ "$FIRST_RUN" = 1 ]; then read_audit -ts recent; else read_audit; fi
RC=$?

case "$RC" in
  0|1) ;;                       # 1 = no matching events, which is the usual answer
  10|11|12)
    # ausearch(8): the checkpoint is invalid, or the log it pointed into rotated
    # away. Start again from a bounded window rather than from the beginning.
    rm -f "$CK"
    say "audit-tail: checkpoint invalid/rotated (rc=$RC), reset"
    read_audit -ts recent
    RC2=$?
    case "$RC2" in
      0|1) ;;
      *) say "audit-tail: re-read after checkpoint reset failed (rc=$RC2): $(head -n 1 "$ERR" 2>/dev/null)"; exit 0 ;;
    esac
    ;;
  *)
    # Nothing was consumed: put the checkpoint back so the next tick re-reads
    # the same events rather than losing them.
    say "audit-tail: ausearch rc=$RC: $(head -n 1 "$ERR" 2>/dev/null)"
    [ -f "$CK.prev" ] && cp -f "$CK.prev" "$CK" 2>/dev/null
    exit 0
    ;;
esac

BOX=""
[ -r "$H/state/box-id" ] && BOX=$(tr -dc 'A-Za-z0-9._-' < "$H/state/box-id" 2>/dev/null)
[ -n "$BOX" ] || BOX=$(hostname 2>/dev/null | tr -dc 'A-Za-z0-9._-')
[ -n "$BOX" ] || BOX=unknown-box

# The FIRST ` <key>=` on the line, never the last. The burst line is built in a
# contracted order, so the first match is the field the parser wrote; a later
# one can only be something an audit-controlled value carried in. The parser
# %20-encodes every such value (path, comm, exe, cwd, lane, claim, session) so
# nothing should reach here with a space in it at all — this is the second lock
# on the same door, because an id that names the wrong pid is an alert that
# points investigators at an innocent process.
field() { # field <line> <key>
  local s=" $1" k="$2" v
  case "$s" in *" $k="*) v="${s#* $k=}"; printf '%s' "${v%% *}" ;; *) printf '' ;; esac
}

# Best effort, and only when the pure resolver found nothing: the process may
# still be alive, and its ancestry names the lane. Untested (a live /proc cannot
# be fixtured); it only ever REPLACES `unresolved`, so a wrong answer here can
# never hide a burst.
proc_lane() { # proc_lane <pid>
  local p="$1" hops=0 cmd st rest proj key x
  while [ "$hops" -lt 20 ] && [ -n "$p" ] && [ "$p" != 0 ] && [ -d "/proc/$p" ]; do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *run-build.sh\ *)
        proj=$(printf '%s' "$cmd" | sed -n 's|.*run-build\.sh  *\([^ ]*\) .*|\1|p')
        key=$(printf '%s' "$cmd" | sed -n 's|.*run-build\.sh  *[^ ]*  *[^ ]*  *\([^ ]*\).*|\1|p')
        if [ -n "$proj" ] && [ -n "$key" ]; then printf 'build:%s/%s' "$proj" "$key"; return 0; fi
        ;;
    esac
    x=$(printf '%s' "$cmd" | sed -n 's|.*/root/harness/bin/\([A-Za-z0-9_-]*\)\.sh.*|\1|p')
    if [ -n "$x" ]; then printf 'cron:%s' "$x"; return 0; fi
    st=$(cat "/proc/$p/stat" 2>/dev/null) || return 1
    rest="${st##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    p="${2:-}"
    hops=$((hops + 1))
  done
  return 1
}

# Every burst is logged, in the order it was seen, before anything is paged.
# A burst can be logged and not paged (over the cap, or a crash between the
# two); it can never be paged and lost.
CRIT=(); INFO=()
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  PID=$(field "$LINE" pid)
  if [ "$(field "$LINE" lane)" = unresolved ] && [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    NEW=$(proc_lane "$PID") || NEW=""
    [ -n "$NEW" ] && LINE="${LINE/ lane=unresolved / lane=$NEW }"
  fi
  say "$LINE"
  if [ "$(field "$LINE" sev)" = critical ]; then CRIT+=("$LINE"); else INFO+=("$LINE"); fi
done < <(parse_bursts < "$TMP")

# The cap is spent CRITICAL FIRST. A tick is a five-minute window and the info
# lane is the loud one (log truncation, scratch files, a build releasing its
# claim), so first-seen order hands every slot to the noise and reports the one
# burst that mattered as "+1 more bursts this tick". Severity order costs
# nothing, changes no line, and is the difference between a page and a
# grep-tomorrow. Within a severity the first-seen order is kept.
SENT=0; OVER=0
for LINE in ${CRIT[@]+"${CRIT[@]}"} ${INFO[@]+"${INFO[@]}"}; do
  if [ "$SENT" -ge "$CAP" ]; then OVER=$((OVER + 1)); continue; fi
  PID=$(field "$LINE" pid)
  FIRST=$(field "$LINE" first)
  SER="${FIRST##*:}"
  if [ "$(field "$LINE" sev)" = critical ]; then
    "$H/bin/lane-alert.sh" --critical --id "audit:$BOX:$PID:$SER" --severity critical audit-tail "$LINE" >/dev/null 2>&1 || true
  else
    "$H/bin/lane-alert.sh" --id "audit:$BOX:$PID:$SER" --severity info audit-tail "$LINE" >/dev/null 2>&1 || true
  fi
  SENT=$((SENT + 1))
done

[ "$OVER" -gt 0 ] && say "+$OVER more bursts this tick, see logs/audit-tail.log"
exit 0
