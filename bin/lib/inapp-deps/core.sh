#!/bin/bash
# bin/lib/inapp-deps/core.sh — BH-3946: reading `Blocked by` text lines and
# judging them. Sourced by bin/lib/inapp-deps.sh, never executed.
#
# Filled by BH-3963 (slice 2 of 4). Nothing here calls a model: the reader is
# a regex over the ticket's own text, the judge reads the board listing, this
# box's PR list and split-chain's merged record. No board or GitHub write; the
# one file written is the `<id>.held` watermark the release sibling reads.
# shellcheck shell=bash

# inapp_deps_lines <ticket-file> <self-actors>
#   IN:  a raw ticket JSON file; the space-separated self actors whose comments
#        are not the client's.
#   OUT: one line per dependency the ticket text declares, or `NONE`.
#        `PRIMITIVE` when the board served a `blocked` boolean (the primitive
#        wins and the text is not read). An unreadable file is `NONE`.
#   A dependency line starts (after markdown noise) with `Blocked by`,
#   `Blocked-by` or `Needs`; its refs are board keys (`TK-12`) or `#N`. A
#   `build after <KEY>` line counts only when the description also has
#   `Order: n of N` and `Part of #KEY` lines (a decompose child). Code spans,
#   fenced blocks, <pre> and <code> are removed first. The newest comment that
#   is not internal and not a self actor's, and carries a dependency line,
#   decides the whole set; failing that the description does. A `Blocked by`
#   line with no ref (`Blocked-by: none`) is a dependency line with an empty
#   set; a `Needs` line with no ref is not a dependency line at all. A ticket's
#   own key is dropped.
inapp_deps_lines() {
  ID_SELF="${2:-}" python3 - "${1:-}" <<'PY'
import html, json, os, re, sys

def out(refs):
    print("\n".join(refs) if refs else "NONE")
    sys.exit(0)

try:
    with open(sys.argv[1]) as f:
        raw = json.load(f)
except Exception:
    out([])
if not isinstance(raw, dict):
    out([])
t = raw.get("ticket") if isinstance(raw.get("ticket"), dict) else raw
for o in (raw, t):
    if isinstance(o.get("blocked"), bool):
        print("PRIMITIVE")
        sys.exit(0)

def text(h):
    if not isinstance(h, str):
        return ""
    s = re.sub(r"(?is)<pre\b[^>]*>.*?</pre>", "", h)
    s = re.sub(r"(?is)<code\b[^>]*>.*?</code>", "", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</li>|</div>", "\n", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s)
    kept, fence = [], None
    for line in s.split("\n"):
        m = re.match(r"^\s*(```|~~~)", line)
        if fence:
            if m and m.group(1) == fence:
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        kept.append(line)
    s = "\n".join(kept)
    s = re.sub(r"`[^`\n]*`", "", s)
    return re.sub(r"`[^\n]*", "", s)

line_re = re.compile(r"^[\s>*_\-#]*(blocked[- ]by|needs)\b(.*)$", re.IGNORECASE | re.MULTILINE)
after_re = re.compile(r"^[\s>*_\-#]*build after\b(.*)$", re.IGNORECASE | re.MULTILINE)
ref_re = re.compile(r"#(\d+)|(?<![A-Za-z0-9])([A-Za-z]{1,10}-\d+)(?![A-Za-z0-9])")

def first(o, *names):
    for n in names:
        v = o.get(n)
        if v not in (None, ""):
            return v
    return ""

desc = text(first(t, "description", "body", "content"))
has_order = bool(re.search(r"^\s*Order:\s*\d+\s+of\s+\d+", desc, re.I | re.M)) and \
            bool(re.search(r"^\s*Part of\s+#?[A-Za-z]*-?\d+", desc, re.I | re.M))

def deps(s):
    found, refs = False, []
    def add(tail, keys_only=False):
        n = 0
        for a, b in ref_re.findall(tail):
            if keys_only and not b:
                continue
            r = ("#" + a) if a else b.upper()
            n += 1
            if r not in refs:
                refs.append(r)
        return n
    for m in line_re.finditer(s):
        n = add(m.group(2))
        if n or m.group(1).lower() != "needs":
            found = True
    if has_order:
        for m in after_re.finditer(s):
            if add(m.group(1), keys_only=True):
                found = True
    return found, refs

me = (os.environ.get("ID_SELF") or "").strip().lower()
selves = set(me.split()) | ({me} if me else set())
comments = raw.get("comments") or t.get("comments") or (raw.get("data") or {}).get("comments") or []
if not isinstance(comments, list):
    comments = []
def is_self(c):
    a = c.get("author")
    who = [a.get("name"), a.get("userId")] if isinstance(a, dict) else [a]
    return any(isinstance(w, str) and w.strip().lower() in selves for w in who)
cand = [c for c in comments if isinstance(c, dict) and isinstance(c.get("body"), str)
        and c.get("isInternal") is not True and not is_self(c)]
cand.sort(key=lambda c: str(c.get("createdAt") or c.get("created_at") or ""), reverse=True)

refs = None
for c in cand:
    found, r = deps(text(c["body"]))
    if found:
        refs = r
        break
if refs is None:
    refs = deps(desc)[1]
own = str(t.get("key") or "").upper()
num = str(t.get("number") or "")
out([r for r in refs if r != own and not (num and r == "#" + num)])
PY
}

# _id_judge <mode> <refs-file> <rows-file> <keymap-file> <prs-file> <fetched-dir>
#   Fields are \x1f-separated (tab is IFS whitespace: empty fields collapse).
#   mode `missing`: `<ref> <keymap-id>` for every ref the listing does not hold
#     and the keymap maps.
#   mode `judge`: `<ref> <SATISFIED|OPEN|UNKNOWN> <key> <id> <detail>` per
#     ref, from the listing row or <fetched-dir>/<keymap-id>.json. SATISFIED is
#     status done/closed or a merged PR for the key; split-chain is the
#     caller's. An unreadable PR file is no evidence, never "no PRs".
_id_judge() {
  python3 - "$@" <<'PY'
import json, os, re, sys
mode, refsf, rowsf, kmf, prsf, fdir = sys.argv[1:7]

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None

refs = [l.strip() for l in open(refsf) if l.strip()]
rows = load(rowsf)
if isinstance(rows, dict):
    rows = rows.get("tickets")
rows = [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
km = load(kmf)
km = km if isinstance(km, dict) else {}
prs = load(prsf)
prs = [p for p in prs if isinstance(p, dict)] if isinstance(prs, list) else []

def key_of(r):
    k = r.get("key")
    if not k and r.get("keyPrefix") and r.get("number") is not None:
        k = "%s-%s" % (r["keyPrefix"], r["number"])
    if not k:
        k = km.get(str(r.get("id")))
    return str(k or "").upper()

def match(ref):
    for r in rows:
        if ref.startswith("#"):
            if str(r.get("number")) == ref[1:]:
                return r
        elif key_of(r) == ref:
            return r
    return None

def head(p):
    h = p.get("head")
    return str(h.get("ref") or "") if isinstance(h, dict) else ""

for ref in refs:
    r = match(ref)
    kmid = "" if ref.startswith("#") else str(km.get(ref) or "")
    if r is None and kmid:
        f = load(os.path.join(fdir, kmid + ".json"))
        if isinstance(f, dict):
            r = f.get("ticket") if isinstance(f.get("ticket"), dict) else f
            r = dict(r, id=r.get("id") or kmid)
            r.setdefault("key", ref)
    if mode == "missing":
        if r is None and kmid:
            print("%s\x1f%s" % (ref, kmid))
        continue
    if r is None:
        print("%s\x1fUNKNOWN\x1f%s\x1f\x1f" % (ref, "" if ref.startswith("#") else ref))
        continue
    key, rid = key_of(r), str(r.get("id") or "")
    st = str(r.get("status") or "").lower()
    hre = re.compile(r"^ticket/%s(-r\d+)?$" % re.escape(key.lower())) if key else None
    def mine(p, by_title):
        return bool(hre and hre.match(head(p))) or \
               (by_title and bool(key) and str(p.get("title") or "").upper().startswith(key + ":"))
    if st in ("done", "closed") or any(p.get("merged_at") and mine(p, True) for p in prs):
        print("%s\x1fSATISFIED\x1f%s\x1f%s\x1f" % (ref, key, rid))
        continue
    det = ""
    for p in prs:
        if p.get("state") == "open" and not p.get("draft") and mine(p, False):
            det = "%s|%s" % (head(p), p.get("html_url") or "")
            break
    print("%s\x1fOPEN\x1f%s\x1f%s\x1f%s" % (ref, key, rid, det))
PY
}

# inapp_deps_eval <project> <ticket-file> <rows-file> <prs-file>
#   IN:  the project, the raw ticket, the board rows and this box's PR records.
#        Reads $HARNESS (else $H) for the keymap, board-fetch.sh and
#        split-chain, and the gate's BASE/BP/TOKEN for the keymap by-id
#        refetch (at most INAPP_DEPS_MAX_LOOKUPS of them). No root, or no gate
#        globals, means no keymap lookup and no split-chain probe.
#   OUT: zero or more per-dependency lines
#          `<ref>\t<SATISFIED|OPEN|UNKNOWN>\t<key>\t<id>\t<detail>`
#        then exactly one final line
#          `VERDICT\t<CLEAR|BLOCKED|STACKABLE|NONE|PRIMITIVE>\t<keys>\t<base>\t<pr-url>`.
#   A ref the board cannot resolve is UNKNOWN, which DEP_UNKNOWN_MODE decides
#   (soft releases, hard holds). STACKABLE = exactly one OPEN with an open,
#   non-draft PR and no held UNKNOWN; BLOCKED keys are comma-joined. A reader
#   that could not run is BLOCKED `unreadable`, never NONE.
inapp_deps_eval() {
  local p="${1:-}" tf="${2:-}" rows="${3:-}" prs="${4:-}" root="${HARNESS:-${H:-}}"
  local refs td mode="soft" km="" ref kmid n=0 st key id det line out=""
  local nopen=0 okey="" obase="" ourl="" keys="" held_unknown=0
  refs=$(inapp_deps_lines "$tf" "${SELF_ACTORS:-}")
  case "$refs" in
    NONE|PRIMITIVE) printf 'VERDICT\t%s\t\t\t\n' "$refs"; return 0 ;;
    '') printf 'VERDICT\tBLOCKED\tunreadable\t\t\n'; return 0 ;;
  esac
  td=$(mktemp -d "${TMPDIR:-/tmp}/inapp-deps-eval.XXXXXX") \
    || { printf 'VERDICT\tBLOCKED\tunreadable\t\t\n'; return 0; }
  printf '%s\n' "$refs" > "$td/refs"
  [ -n "$root" ] && [ -n "$p" ] && km="$root/state/$p.keymap.json"
  [ -n "$km" ] || km="$td/none"
  if [ -n "$root" ] && [ -n "${BASE:-}" ] && [ -n "${BP:-}" ] && [ -n "${TOKEN:-}" ]; then
    command -v _inapp_deps_knobs >/dev/null 2>&1 && _inapp_deps_knobs
    while IFS=$'\x1f' read -r ref kmid; do
      [ -n "$kmid" ] || continue
      [ "$n" -lt "${INAPP_DEPS_MAX_LOOKUPS:-10}" ] || break
      n=$((n + 1))
      case "$kmid" in *[!A-Za-z0-9_.-]*) continue ;; esac
      INTERNAL_TOKEN="$TOKEN" "$root/bin/board-fetch.sh" "$BASE$BP/tickets/$kmid" --full \
        > "$td/$kmid.json" 2>/dev/null || rm -f "$td/$kmid.json"
    done < <(_id_judge missing "$td/refs" "$rows" "$km" "$prs" "$td" 2>/dev/null)
  fi
  if [ -n "$root" ] && ! declare -F dep_unknown_mode >/dev/null 2>&1; then
    # shellcheck source=bin/lib/dep-verify-lib.sh
    [ -r "${_ID_LIBDIR:-}/dep-verify-lib.sh" ] && . "${_ID_LIBDIR:-}/dep-verify-lib.sh" 2>/dev/null
  fi
  declare -F dep_unknown_mode >/dev/null 2>&1 && mode=$(dep_unknown_mode "$root")
  while IFS=$'\x1f' read -r ref st key id det; do
    [ -n "$ref" ] || continue
    if [ "$st" = OPEN ] && [ -n "$root" ] && [ -n "$key" ]; then
      if ! declare -F split_chain_key_merged >/dev/null 2>&1; then
        # shellcheck source=bin/lib/split-chain.sh
        [ -r "${_ID_LIBDIR:-}/split-chain.sh" ] && . "${_ID_LIBDIR:-}/split-chain.sh" 2>/dev/null
      fi
      if declare -F split_chain_key_merged >/dev/null 2>&1 \
         && split_chain_key_merged "$root" "$p" "$key" >/dev/null 2>&1; then
        st=SATISFIED; det=""
      fi
    fi
    line=$(printf '%s\t%s\t%s\t%s\t%s' "$ref" "$st" "$key" "$id" "$det")
    out="$out$line"$'\n'
    case "$st" in
      OPEN) nopen=$((nopen + 1)); keys="$keys,${key:-$ref}"
            [ -n "$det" ] && { okey="${key:-$ref}"; obase="${det%%|*}"; ourl="${det#*|}"; } ;;
      UNKNOWN) [ "$mode" = hard ] && { held_unknown=1; keys="$keys,$ref"; } ;;
    esac
  done < <(_id_judge judge "$td/refs" "$rows" "$km" "$prs" "$td" 2>/dev/null)
  rm -rf "$td"
  if [ -z "$out" ]; then printf 'VERDICT\tBLOCKED\tunreadable\t\t\n'; return 0; fi
  printf '%s' "$out"
  if [ -z "$keys" ]; then
    printf 'VERDICT\tCLEAR\t\t\t\n'
  elif [ "$nopen" = 1 ] && [ "$held_unknown" = 0 ] && [ -n "$obase" ]; then
    printf 'VERDICT\tSTACKABLE\t%s\t%s\t%s\n' "$okey" "$obase" "$ourl"
  else
    printf 'VERDICT\tBLOCKED\t%s\t\t\n' "${keys#,}"
  fi
}

# _id_board_id <harness> <project> <ticket-file> <ticket-id> — the board this
# ticket is on: its own boardId, else the gate fingerprint's board holding it,
# else the only board /boards lists. Nothing when none of those answers.
_id_board_id() {
  local b t
  b=$(jq -r '(.boardId? // .ticket?.boardId? // "") | tostring' "$3" 2>/dev/null) || b=""
  if [ -z "$b" ] && [ -r "$1/state/$2.gate.json" ]; then
    b=$(jq -r --arg id "$4" '[to_entries[] | select([.value[]? | objects | .id | tostring] | index($id)) | .key][0] // ""' \
        "$1/state/$2.gate.json" 2>/dev/null) || b=""
  fi
  if [ -z "$b" ]; then
    t=$(curl -sS -m 20 -H "Authorization: Bearer $TOKEN" -H 'User-Agent: curl/8' "$BASE$BP/boards" 2>/dev/null) || t=""
    b=$(printf '%s' "$t" | jq -r '(if type == "array" then . else .boards end) as $b
          | if ($b | type) == "array" and ($b | length) == 1 then $b[0].id | tostring else "" end' 2>/dev/null) || b=""
  fi
  printf '%s' "$b"
}

# inapp_deps_buildable <harness> <project> <raw-ticket-file> <strict 0|1>
#   OUT: ONE complete gate answer line such as `BLOCKED dependencies TK-12` or
#        `BLOCKED unreadable` when the ticket must be refused, which
#        bin/triage-gate.sh --buildable prints as its answer; nothing to fall
#        through to the rest of buildable_gate.
#   RC:  never decides. bin/triage-gate.sh takes the first printed line whatever
#        the rc, so a nonzero return with a line is still a refusal, and a
#        nonzero return with nothing printed still falls through.
#   Reads the calling gate's BASE, BP, TOKEN and SELF_ACTORS. A ticket already
#   in_progress/review/done/closed, or whose text declares no dependency, prints
#   nothing before any fetch. A trimmed thread (board-fetch `_omitted`) is
#   re-read --full once. An unreadable board id or listing prints nothing, or
#   `BLOCKED unreadable` when strict. A failed PR list is no evidence. BLOCKED
#   and STACKABLE both touch <inapp_deps_state_dir>/<id>.held.
inapp_deps_buildable() {
  local h="${1:-}" p="${2:-}" f="${3:-}" strict="${4:-0}" td rc=0
  td=$(mktemp -d "${TMPDIR:-/tmp}/inapp-deps-gate.XXXXXX") || return 0
  _id_buildable "$h" "$p" "$f" "$strict" "$td" || rc=$?
  rm -rf "$td"
  return "$rc"
}

_id_buildable() {
  local h="$1" p="$2" f="$3" strict="$4" td="$5" unread="" st tid refs bid code slug v sd
  local vt vk
  st=$(jq -r '(.status? // .ticket?.status? // "") | tostring | ascii_downcase' "$f" 2>/dev/null) || st=""
  case "$st" in in_progress|review|done|closed) return 0 ;; esac
  tid=$(jq -r '(.id? // .ticket?.id? // "") | tostring' "$f" 2>/dev/null) || tid=""
  if [ -n "$tid" ] && [ -n "${BASE:-}" ] && [ -n "${BP:-}" ] && [ -n "${TOKEN:-}" ] \
     && jq -e '[.. | objects | select(has("_omitted"))] | length > 0' "$f" >/dev/null 2>&1 \
     && INTERNAL_TOKEN="$TOKEN" "$h/bin/board-fetch.sh" "$BASE$BP/tickets/$tid" --full > "$td/full.json" 2>/dev/null \
     && jq -e 'type == "object"' "$td/full.json" >/dev/null 2>&1; then
    f="$td/full.json"
  fi
  [ "$strict" = 1 ] && unread="BLOCKED unreadable"
  refs=$(inapp_deps_lines "$f" "${SELF_ACTORS:-}")
  case "$refs" in
    NONE|PRIMITIVE) return 0 ;;
    '') [ -n "$unread" ] && printf '%s\n' "$unread"; return 0 ;;
  esac
  case "$tid" in ''|*[!A-Za-z0-9_.-]*) [ -n "$unread" ] && printf '%s\n' "$unread"; return 0 ;; esac
  if [ -z "$h" ] || [ -z "${BASE:-}" ] || [ -z "${BP:-}" ] || [ -z "${TOKEN:-}" ]; then
    [ -n "$unread" ] && printf '%s\n' "$unread"; return 0
  fi
  bid=$(_id_board_id "$h" "$p" "$f" "$tid")
  [ -n "$bid" ] || { [ -n "$unread" ] && printf '%s\n' "$unread"; return 0; }
  code=$(curl -sS -m 20 -o "$td/rows.json" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
         -H 'User-Agent: curl/8' "$BASE$BP/boards/$bid/tickets" 2>/dev/null) || code=000
  case "$code" in
    2??) jq -e . "$td/rows.json" >/dev/null 2>&1 || code=bad ;;
  esac
  case "$code" in 2??) ;; *) [ -n "$unread" ] && printf '%s\n' "$unread"; return 0 ;; esac
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  if [ -n "$slug" ]; then
    if ! declare -F gh_rest_pr_list >/dev/null 2>&1; then
      # shellcheck source=bin/lib/gh-rest.sh
      [ -r "${_ID_LIBDIR:-}/gh-rest.sh" ] && . "${_ID_LIBDIR:-}/gh-rest.sh" 2>/dev/null
    fi
    if ! declare -F gh_rest_pr_list >/dev/null 2>&1 \
       || ! gh_rest_pr_list "$slug" all "" 100 > "$td/prs.json" 2>/dev/null \
       || ! jq -e 'type == "array"' "$td/prs.json" >/dev/null 2>&1; then
      rm -f "$td/prs.json"
    fi
  fi
  v=$(HARNESS="$h" inapp_deps_eval "$p" "$f" "$td/rows.json" "$td/prs.json")
  v=${v##*$'\n'}
  IFS=$'\t' read -r _ vt vk _ <<<"$v"
  case "$vt:$vk" in
    BLOCKED:unreadable) [ -n "$unread" ] && printf '%s\n' "$unread" ;;
    BLOCKED:*|STACKABLE:*)
      [ "$vt" = BLOCKED ] && printf 'BLOCKED dependencies %s\n' "${vk:-unlisted}"
      sd=$(inapp_deps_state_dir "$h" "$p") && mkdir -p "$sd" 2>/dev/null && touch "$sd/$tid.held" 2>/dev/null ;;
  esac
  return 0
}
