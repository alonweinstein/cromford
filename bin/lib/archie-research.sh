#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-research.sh — BH-4065 (BH-3966.4): the pure helpers behind
# Archie's research scout. Sourced by bin/archie-research.sh, never run.
#
#   ar_canon_url <url>        -> the canonical url, rc 0; rc 1 for anything
#                                that is not an http(s) url with a host, over
#                                2000 chars, or carrying a user:password.
#                                https, lowercase host without www., no
#                                fragment, no tracking params (utm_*, fbclid,
#                                gclid, ref, ref_src, s, t), the rest sorted,
#                                no trailing /. twitter.com and mobile hosts
#                                fold into x.com. YouTube (BH-4762): www./m./
#                                music.youtube.com fold into youtube.com,
#                                youtu.be/<id> and /shorts/<id> into
#                                youtube.com/watch?v=<id>, and si, feature
#                                and pp are dropped on YouTube only, so one
#                                video is one key.
#   ar_is_video <url>         -> rc 0 when the canonical host is youtube.com
#                                (BH-4762), rc 1 otherwise or for junk.
#   ar_item_key <url> [post_id] -> x:<digits> for an X post (from a
#                                x.com/<user>/status/<id> url or the post id),
#                                else web:<first 40 hex of sha256(canonical
#                                url)>. rc 1 on junk: a post id that is not all
#                                digits is refused, never trimmed, and a post
#                                id that disagrees with the url is refused.
#   ar_items_norm             -> stdin JSONL finds {source, url, post_id,
#                                title, text}; stdout the same with `key` and
#                                the canonical `url`, junk dropped, one line
#                                per key (the first wins). THE one normaliser:
#                                ar_canon_url and ar_item_key run the same code.
#   ar_topic_slug <topic>     -> lowercase, [^a-z0-9]+ to -, at most 48 chars.
#   ar_xai_body <model> <topic> <from-date> <prompt-file>
#                             -> the JSON request for POST <xai>/v1/responses
#                                with the x_search tool.
#   ar_xai_parse <response-file>
#                             -> line 1: usage `in<TAB>out<TAB>tool_calls`,
#                                each BLANK when the answer does not say
#                                (never 0); lines 2+: one compact JSON post per
#                                line {post_id, url, author, text}. rc 0 items,
#                                rc 2 the answer parsed and holds no item
#                                (empty), rc 1 unparseable (usage line still
#                                printed when the envelope is JSON).
#   ar_answer_array <file>    -> the first JSON array in a model's answer (a
#                                ```json fence or prose around it is fine),
#                                compact, rc 0; rc 1 when there is none.
#   ar_price <model> <in> <out> <tool_calls>
#                             -> USD to 6dp: tokens through cost_price_tokens
#                                (bin/lib/cost-row.sh, the one formula, the
#                                caller's to source) plus tool_calls x
#                                ARCHIE_XAI_TOOL_CALL_USD (0.005). Tokens
#                                that cannot be priced print NOTHING, rc 1. A
#                                blank tool count prices the tokens alone.
#
# Root: ${HARNESS:-${H:-}} only (D43). Nothing here reads a path from it.

# The normaliser's program, held in a variable so `items` can read its data
# on stdin (python3 - would read the program from there).
_AR_PY=$(cat <<'PY'
import hashlib, json, re, sys
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit

DROP = {"fbclid", "gclid", "ref", "ref_src", "s", "t"}
X_HOSTS = {"x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com"}
YT_HOSTS = {"youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}
YT_DROP = {"si", "feature", "pp"}

def canon(u):
    if not isinstance(u, str) or not u or len(u) > 2000 or re.search(r"\s", u):
        return None
    try:
        p = urlsplit(u)
        port = p.port
    except ValueError:
        return None
    scheme = p.scheme.lower()
    if scheme not in ("http", "https") or not p.hostname or "@" in p.netloc:
        return None
    host = p.hostname.lower()
    if host.startswith("www."):
        host = host[4:]
    if host in X_HOSTS:
        host = "x.com"
    path = p.path.rstrip("/")
    qs = parse_qsl(p.query, keep_blank_values=True)
    if host in YT_HOSTS:
        m = re.fullmatch(r"/(?:shorts/)?([A-Za-z0-9_-]{1,64})", path) if host == "youtu.be" or path.startswith("/shorts/") else None
        if m:
            path = "/watch"
            qs = [(k, v) for k, v in qs if k != "v"] + [("v", m.group(1))]
        host, port = "youtube.com", None
        qs = [(k, v) for k, v in qs if k.lower() not in YT_DROP]
    netloc = host + (":%d" % port if port and port not in (80, 443) else "")
    q = sorted((k, v) for k, v in qs
               if not k.lower().startswith("utm_") and k.lower() not in DROP)
    return urlunsplit(("https", netloc, path, urlencode(q), ""))

POST = re.compile(r"^/(?:[^/]+|i(?:/web)?)/status/(\d{1,25})(?:/.*)?$")

def key(u, pid):
    pid = "" if pid is None else str(pid)
    if pid != "" and not re.fullmatch(r"\d{1,25}", pid):
        return None, None
    c = canon(u) if u else None
    if u and c is None:
        return None, None
    uid = None
    if c:
        p = urlsplit(c)
        m = POST.match(p.path) if p.hostname == "x.com" else None
        uid = m.group(1) if m else None
    if pid and uid and pid != uid:
        return None, None
    pid = pid or uid
    if pid:
        return "x:" + pid, c or ("https://x.com/i/status/" + pid)
    if not c:
        return None, None
    return "web:" + hashlib.sha256(c.encode()).hexdigest()[:40], c

mode = sys.argv[1]
if mode == "canon":
    c = canon(sys.argv[2])
    if c is None:
        sys.exit(1)
    print(c)
elif mode == "key":
    k, _ = key(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    if k is None:
        sys.exit(1)
    print(k)
elif mode == "items":
    seen = set()
    for line in sys.stdin:
        try:
            it = json.loads(line)
        except ValueError:
            continue
        if not isinstance(it, dict):
            continue
        k, c = key(it.get("url") or "", it.get("post_id"))
        if k is None or k in seen:
            continue
        seen.add(k)
        it["key"], it["url"] = k, c
        print(json.dumps(it, separators=(",", ":")))
PY
)
_ar_py() { python3 -c "$_AR_PY" "$@"; }

ar_canon_url() { _ar_py canon "${1:-}"; }
ar_item_key() { _ar_py key "${1:-}" "${2:-}"; }
ar_items_norm() { _ar_py items; }
ar_is_video() { local c; c=$(_ar_py canon "${1:-}") || return 1; [[ $c == https://youtube.com/* ]]; }

ar_topic_slug() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-48 | sed -E 's/-+$//'
}

ar_xai_body() {
  local model="${1:-}" topic="${2:-}" from="${3:-}" pf="${4:-}"
  [ -n "$model" ] && [ -n "$topic" ] && [[ $from =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -r "$pf" ] || return 1
  jq -n --arg m "$model" --arg t "$topic" --arg f "$from" --rawfile p "$pf" \
    '{model: $m,
      input: [{role: "user", content: ($p + "\n\nTopic: " + $t + "\nOnly posts from " + $f + " on.")}],
      tools: [{type: "x_search", from_date: $f}]}'
}

ar_xai_parse() {
  local f="${1:-}"
  [ -r "$f" ] || { printf '\t\t\n'; return 1; }
  python3 - "$f" <<'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except (ValueError, OSError):
    print("\t\t"); sys.exit(1)
if not isinstance(d, dict):
    print("\t\t"); sys.exit(1)
u = d.get("usage") if isinstance(d.get("usage"), dict) else {}
def n(v):
    return str(v) if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else ""
tc = ""
st = u.get("server_side_tool_usage")
if isinstance(st, dict) and st and all(isinstance(v, int) for v in st.values()):
    tc = str(sum(st.values()))
elif n(st):
    tc = n(st)
elif n(u.get("num_server_side_tools_used")):
    tc = n(u.get("num_server_side_tools_used"))
elif n(u.get("num_sources_used")):
    tc = n(u.get("num_sources_used"))
print("%s\t%s\t%s" % (n(u.get("input_tokens")), n(u.get("output_tokens")), tc))
texts = []
for o in d.get("output") or []:
    if isinstance(o, dict) and o.get("type") == "message":
        for c in o.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "output_text" and isinstance(c.get("text"), str):
                texts.append(c["text"])
if not texts and isinstance(d.get("output_text"), str):
    texts.append(d["output_text"])
text = "\n".join(texts)
m = re.search(r"\[.*\]", text, re.S)
if not m:
    sys.exit(1)
try:
    arr = json.loads(m.group(0))
except ValueError:
    sys.exit(1)
if not isinstance(arr, list):
    sys.exit(1)
out = 0
for it in arr:
    if not isinstance(it, dict):
        continue
    pid = it.get("post_id")
    pid = str(pid) if isinstance(pid, (int, str)) and not isinstance(pid, bool) else ""
    url = it.get("url") if isinstance(it.get("url"), str) else ""
    if not pid and not url:
        continue
    print(json.dumps({"post_id": pid, "url": url,
                      "author": str(it.get("author") or "")[:100],
                      "text": str(it.get("text") or "")[:1000]}, separators=(",", ":")))
    out += 1
sys.exit(0 if out else 2)
PY
}

ar_answer_array() {
  [ -r "${1:-}" ] || return 1
  python3 - "$1" <<'PY'
import json, re, sys
text = open(sys.argv[1], errors="replace").read()
m = re.search(r"\[.*\]", text, re.S)
if not m:
    sys.exit(1)
try:
    arr = json.loads(m.group(0))
except ValueError:
    sys.exit(1)
if not isinstance(arr, list):
    sys.exit(1)
print(json.dumps(arr, separators=(",", ":")))
PY
}

ar_price() {
  local model="${1:-}" in="${2:-}" out="${3:-}" tc="${4:-}" tok per
  command -v cost_price_tokens >/dev/null 2>&1 || return 1
  [ -n "$in$out" ] || return 1
  tok=$(cost_price_tokens "$model" "$in" "$out" "" "") || return 1
  [ -n "$tok" ] || return 1
  per="${ARCHIE_XAI_TOOL_CALL_USD:-0.005}"
  [[ $per =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ $tc =~ ^[0-9]+$ ]] || tc=0
  awk -v a="$tok" -v n="$tc" -v p="$per" 'BEGIN { printf "%.6f", a + n * p }'
}
