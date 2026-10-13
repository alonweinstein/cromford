# shellcheck shell=bash
# bin/lib/triage-inbox.sh — alert-triage's per-project inboxes (BH-5942, C3).
#
# The quarantine reads are DESTRUCTIVE (`cat` then `: >`, on the hub and over
# ssh on every box), so N project runs cannot each drain a box. The dispatch
# path of bin/alert-triage.sh collects once, as it always has, and routes every
# collected line by its beat `project` to its owner's inbox. A project run then
# reads only its own inbox and its own deferral spool.
#
#   ti_dir                       state/alert-triage (one dir per project)
#   ti_inbox <project>           that project's inbox: lines in the WORK format
#                                source<TAB>epoch<TAB>beat-json
#   ti_route <file>              append every line of <file> to the inbox of the
#                                project that owns it (llp_route of the beat's
#                                .project), each append under <inbox>.lock.
#                                Prints "<p>=<n> ..." for what landed. rc 0 =
#                                every append landed. rc 1 = <file> is rewritten
#                                to hold ONLY the lines that did not land (so a
#                                retry never duplicates what did), and the
#                                output names each failed inbox.
#   ti_move <src> <dest>         append <src> to <dest> under <src>.lock, then
#                                empty <src>. WRITE FIRST, THEN FORGET: <src> is
#                                emptied only after the append succeeded.
#   ti_queued <alert-id>         rc 0 when orclane:<id> is still queued for any
#                                project: in an inbox, a deferral spool or the
#                                work file of a live (or dead) project run.
#   ti_spools_absent             rc 0 when no deferral spool exists at all, the
#                                legacy shared one included (a rebuilt hub).
#   ti_owned_db <dbspool>        keep only the brake:triage-deferred rows whose
#                                line this run (LLP_PROJECT) owns, in place. A
#                                project run must never clear another
#                                project's ledger rows. rc 1 = not filtered.
#   ti_seed <file> <shared>      first run of a project: copy the shared state
#                                file to the project's own (never a move).
#
# The owner of a line: the beat's `project` when it is a plain name, else ""
# (no project, JSON null, not a string, not a name, a torn payload). The name
# is then mapped by llp_route (bin/lib/llm-lane-project.sh): a fleet.conf
# project by exact string, everything else to the home project. Needs $HARNESS.
# Defines functions only. Nothing runs on source.

# shellcheck source=bin/lib/llm-lane-project.sh
command -v llp_route >/dev/null 2>&1 || . "${HARNESS:-${H:-}}/bin/lib/llm-lane-project.sh" || return 1
# shellcheck source=bin/lib/project-lanes.sh
command -v pl_name_ok >/dev/null 2>&1 || . "${HARNESS:-${H:-}}/bin/lib/project-lanes.sh" || return 1

ti_dir() { printf '%s/state/alert-triage' "${HARNESS:-${H:-}}"; }
ti_inbox() { printf '%s/%s/inbox.tsv' "$(ti_dir)" "$1"; }

# _ti_py <mode> <args...> — the one parser. Modes:
#   fields <file>                    distinct owner fields, one per line
#   split <file> <map> <outdir>      write each line to <outdir>/<project>
#   dbfields <dbspool>               the same, for brake rows key<TAB>at<TAB>detail
#   dbkeep <dbspool> <map> <project> print the rows <project> owns (and # rows)
_ti_py() {
  python3 - "$@" <<'PYTI'
import json, os, re, sys
NAME = re.compile(r"[A-Za-z0-9._-]+\Z")
UN = {"\\": "\\", "t": "\t", "n": "\n", "r": "\r"}

def owner(raw):
    for part in reversed(raw.split("\t")):
        part = part.strip()
        if part.startswith("{"):
            try:
                o = json.loads(part)
            except Exception:
                return ""
            p = o.get("project") if isinstance(o, dict) else None
            return p if isinstance(p, str) and NAME.match(p) else ""
    return ""

def db_owner(row):
    parts = row.rstrip("\n").split("\t")
    if len(parts) < 3:
        return ""
    try:
        line = json.loads(re.sub(r"\\(.)", lambda m: UN.get(m.group(1), m.group(0)), parts[2]))["line"]
    except Exception:
        return ""
    return owner(line) if isinstance(line, str) else ""

def lines(path):
    with open(path, "rb") as fh:
        for b in fh:
            if b.strip():
                yield b if b.endswith(b"\n") else b + b"\n"

def load_map(path):
    m = {}
    for row in open(path, errors="replace"):
        k, _, v = row.rstrip("\n").partition("\t")
        m[k] = v
    return m

mode = sys.argv[1]
if mode == "fields":
    seen = {owner(b.decode("utf-8", "replace")) for b in lines(sys.argv[2])}
    sys.stdout.write("".join(f + "\n" for f in sorted(seen)))
elif mode == "split":
    m, out = load_map(sys.argv[3]), sys.argv[4]
    fhs = {}
    for b in lines(sys.argv[2]):
        p = m.get(owner(b.decode("utf-8", "replace")), "")
        if not NAME.match(p or ""):
            raise SystemExit("no owner for a line")
        if p not in fhs:
            fhs[p] = open(os.path.join(out, p), "ab")
        fhs[p].write(b)
    for fh in fhs.values():
        fh.close()
elif mode == "dbfields":
    seen = set()
    for row in open(sys.argv[2], errors="replace"):
        if row.strip() and not row.startswith("#"):
            seen.add(db_owner(row))
    sys.stdout.write("".join(f + "\n" for f in sorted(seen)))
elif mode == "dbkeep":
    m, me = load_map(sys.argv[3]), sys.argv[4]
    for row in open(sys.argv[2], errors="replace"):
        if not row.strip():
            continue
        if row.startswith("#") or m.get(db_owner(row)) == me:
            sys.stdout.write(row if row.endswith("\n") else row + "\n")
PYTI
}

# _ti_map — stdin: owner fields; stdout: field<TAB>project (llp_route).
_ti_map() {
  local f
  while IFS= read -r f; do printf '%s\t%s\n' "$f" "$(llp_route "$f")"; done
}

ti_route() {
  local src="$1" tmp p f n inbox rc=0 landed="" failed=""
  [ -s "$src" ] || return 0
  tmp=$(mktemp -d) || return 1
  mkdir -p "$tmp/out"
  if ! _ti_py fields "$src" > "$tmp/fields" || ! _ti_map < "$tmp/fields" > "$tmp/map" \
     || ! _ti_py split "$src" "$tmp/map" "$tmp/out"; then
    rm -rf "$tmp"; echo "the router could not read the lines"; return 1
  fi
  : > "$tmp/left"
  for f in "$tmp/out"/*; do
    [ -f "$f" ] || continue
    p="${f##*/}"; n=$(grep -c . "$f"); inbox=$(ti_inbox "$p")
    if pl_name_ok "$p" && mkdir -p "${inbox%/*}" 2>/dev/null \
       && ( exec 8>"$inbox.lock" && flock 8 && cat "$f" >> "$inbox" ) 2>/dev/null; then
      landed="${landed:+$landed }$p=$n"
    else
      cat "$f" >> "$tmp/left"; failed="${failed:+$failed, }$p=$n ($inbox)"; rc=1
    fi
  done
  if [ "$rc" = 0 ]; then
    printf '%s\n' "${landed:-nothing}"
  else
    # Only what did not land stays behind, so the next dispatch cannot append
    # a line twice. A rewrite that fails keeps the whole file (a duplicate
    # costs a line, a loss costs the alert).
    cp "$tmp/left" "$src.tmp" 2>/dev/null && mv -f "$src.tmp" "$src" 2>/dev/null
    printf 'landed: %s; could not append %s\n' "${landed:-nothing}" "$failed"
  fi
  rm -rf "$tmp"
  return "$rc"
}

ti_move() {
  local src="$1" dest="$2"
  [ -s "$src" ] || return 0
  ( exec 8>"$src.lock" && flock 8 && { [ ! -s "$src" ] || { cat "$src" >> "$dest" && : > "$src"; }; } ) 2>/dev/null
}

ti_queued() {
  local d; d=$(ti_dir)
  grep -q -F "\"akey\":\"orclane:$1\"" "$d"/*/inbox.tsv "$d"/*/deferred.tsv "$d"/*/work.tsv 2>/dev/null
}

ti_spools_absent() {
  local f
  [ -e "${HARNESS:-${H:-}}/state/alert-triage-deferred.tsv" ] && return 1
  for f in "$(ti_dir)"/*/deferred.tsv; do [ -e "$f" ] && return 1; done
  return 0
}

ti_owned_db() {
  local db="$1" tmp
  [ -n "${LLP_PROJECT:-}" ] && [ -f "$db" ] || return 1
  tmp=$(mktemp -d) || return 1
  if _ti_py dbfields "$db" > "$tmp/fields" && _ti_map < "$tmp/fields" > "$tmp/map" \
     && _ti_py dbkeep "$db" "$tmp/map" "$LLP_PROJECT" > "$tmp/keep" && cat "$tmp/keep" > "$db"; then
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

ti_seed() {
  [ -e "$1" ] || [ ! -s "$2" ] || cp "$2" "$1" 2>/dev/null
  return 0
}
