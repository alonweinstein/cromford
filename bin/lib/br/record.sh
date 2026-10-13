#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/record.sh — BH-1176: the resolver's RECORD layer: the per-(project,
# key) json under $ST, its readers, its writers and the one EVENT line every
# rung transition leaves behind. Sourced by bin/blocked-resolver.sh, never run.
# It reads $ST and $H at CALL time and nothing at source time.
#
# This slice landed DARK (see tests/br-split-layout-test.sh case 4): the block
# below is a BYTE-IDENTICAL copy of the one still inline in
# bin/blocked-resolver.sh, which is sourced FIRST and therefore loses to the
# inline definition. The cut that deletes the inline copy is a separate change,
# and this file is what makes that diff a pure deletion.
# ---------------------------------------------------------------------------
# State. One json per (project, key). rkey is the FILE name, so it is sanitized:
# a conductor key is `example-org/project-5#510` and both of those characters are
# trouble in a path and in a lock name.
# ---------------------------------------------------------------------------
br_rkey() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }
# br_cap_key <project> <rkey> <ticket-key> — the key the REBUILD cap counts on.
# A conductor rkey carries the PR NUMBER, and a rebuild produces a NEW PR, so a
# cap counted on it starts from zero on every rung: 10 -> rebuild -> 11 ->
# rebuild -> 12, for ever. The TICKET is what is being rebuilt, so every rebuild
# of one ticket shares one counter and the ladder is bounded per ticket. The
# queue and build sources already key on the ticket, so this is their key too.
br_cap_key() {
  local p="$1" rkey="$2" tkey="$3"
  case "$tkey" in ''|-) printf '%s' "$rkey" ;; *) br_rkey "$p-$tkey" ;; esac
}
br_file() { echo "$ST/$1/$2.json"; }
br_load() { # br_load <project> <rkey> — prints the json (a fresh one if absent)
  local f row=""; f=$(br_file "$1" "$2")
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  # THE FILE IS GONE: ASK THE ROW (BH-2317). br_save mirrors the counters and
  # the outcome into ledgers(kind=br_record), so a wiped or rebuilt hub gets
  # them back instead of running an ABANDONED ladder again and telling the
  # client twice. Only rc 0 restores; a real miss or an outage is today's zero
  # shape. A miss (or an outage) is remembered in $BR_ROW_MISS for the tick (the
  # lane sets it; br_load runs inside $(...), so a shell variable would not
  # survive), which keeps a never-written key at one read per tick (D21).
  if command -v job_ledger_row >/dev/null 2>&1 \
     && ! { [ -n "${BR_ROW_MISS:-}" ] && grep -qxF "$1/$2" "$BR_ROW_MISS" 2>/dev/null; }; then
    row=$(job_ledger_row br_record "$1/$2" 2>/dev/null </dev/null) \
      || { row=""; [ -n "${BR_ROW_MISS:-}" ] && printf '%s\n' "$1/$2" >> "$BR_ROW_MISS" 2>/dev/null; }
  fi
  printf '%s' "$row" | jq -c --arg p "$1" --arg k "$2" --arg t "$(STAMP)" -n '
    {project:$p,rkey:$k,first_seen:$t,rebuilds:0,fixrounds:0,mechanicals:0,regens:0,adjudications:0,rereviews:0,outcome:"",attempts:[]}
    + ((try input catch null) as $r
       | if ($r | type) != "object" then {} else
           (try ($r.detail | fromjson) catch null) as $d
           | if ($d | type) != "object" then {} else
               ($d | with_entries(select(.key as $x
                   | ["rebuilds","fixrounds","mechanicals","regens","adjudications","rereviews"] | index($x))
                 | select(.value | type == "number")))
               + (if ($d.first_seen | type) == "string" then {first_seen:$d.first_seen} else {} end)
               + {outcome: (if $r.status == "open" then "" else ($r.status // "") end), restored:"ledger"}
             end
         end)'
}
# br_save <project> <rkey> <json> — THE ONE WRITE of a ticket's record
#   (BH-2317). The file first, exactly as every writer did it, and rc 1 when
#   that fails; then the counters and the outcome as a ledgers(kind=br_record)
#   row, fail-open and its rc ignored — br_record's file-then-row order, so a
#   row with no file behind it cannot happen and the next write heals a missed
#   row. status is the outcome (`open` when there is none), detail the counters.
br_save() {
  local f status detail
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s\n' "$3" > "$f" || return 1
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  status=$(printf '%s' "$3" | jq -r '(.outcome // "") | if . == "" then "open" else . end' 2>/dev/null) || return 0
  detail=$(printf '%s' "$3" | jq -c '{rebuilds,fixrounds,mechanicals,regens,adjudications,rereviews,first_seen}' 2>/dev/null) || return 0
  [ -n "$status" ] && job_ledger_put br_record "$1/$2" "$status" "$detail" >/dev/null 2>&1 </dev/null
  return 0
}
br_num() { # br_num <json> <field>
  local v; v=$(printf '%s' "$1" | jq -r "(.$2 // 0)" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}
# br_record <project> <rkey> <action> <reason> <detail> [field-to-bump] [pr-url] [head]
#   Appends the attempt AND bumps its counter in one write. The attempt list is
#   what the ABANDONED alert prints: "what was tried" has to be a fact on disk,
#   not a reconstruction from log greps.
#
#   THE ROW IS THE SECOND WRITE (BH-1388). When the bump is one of the three
#   ladder counters and the caller handed in the PR url, the same attempt is
#   PUT to pr_attempts — mc_attempt_put's ordering exactly (bin/lib/mc/locks.sh):
#   the FILE first, so "a row with no file line" cannot happen, then the row,
#   whose rc is ignored because the file line already exists and the next bump
#   heals the row. The url is an ARGUMENT and not a record field because the
#   record has never carried one (br_load's fresh shape), so the eight bumping
#   call sites pass it and every other caller is unchanged.
br_record() {
  local p="$1" k="$2" act="$3" why="$4" detail="$5" bump="${6:-}" purl="${7:-}" phead="${8:-}"
  local f cur kind slug num
  f=$(br_file "$p" "$k"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$p" "$k")
  # The attempt carries its PR url when the caller handed one in (the fix-round
  # and rebuild call sites do): bin/lib/br/opt/cirepair.sh reads it to tell this
  # PR's rounds from an earlier PR's on a record it has not stamped yet.
  cur=$(printf '%s' "$cur" | jq -c --arg a "$act" --arg w "$why" --arg d "$detail" --arg t "$(STAMP)" --arg u "$purl" \
    '.attempts += [{at:$t,action:$a,reason:$w,detail:$d} + (if $u == "" or $u == "-" then {} else {url:$u} end)] | .updated = $t' 2>/dev/null) || return 1
  [ -n "$bump" ] && cur=$(printf '%s' "$cur" | jq -c --arg b "$bump" '.[$b] = ((.[$b] // 0) + 1)' 2>/dev/null)
  br_save "$p" "$k" "$cur" || return 1
  # A RECORDED RUNG IS RESOLVER ACTIVITY (BH-3630). When the conductor holds a
  # claim for this PR (mc_resolver_claim), its active_at moves, and the
  # conductor's 24h re-page stays quiet while rungs keep landing. No claim, no-op.
  case "$purl" in
    https://github.com/*/pull/*)
      command -v mc_resolver_claim_touch >/dev/null 2>&1 \
        && mc_resolver_claim_touch "$(br_slug_of_url "$purl")#$(mc_num_of_url "$purl")" 2>/dev/null ;;
  esac
  case "$bump" in
    rebuilds)      kind=rebuild ;;
    fixrounds)     kind=fixround ;;
    adjudications) kind=adjudicate ;;
    *)             kind="" ;;
  esac
  case "$purl" in ''|-) kind="" ;; esac
  if [ -n "$kind" ] && type pr_rows_on >/dev/null 2>&1 && pr_rows_on; then
    if slug=$(br_slug_of_url "$purl"); then
      num=$(mc_num_of_url "$purl")
      [ -n "$num" ] && pr_attempt_put "$slug" "$num" "$kind" "${phead:--}" >/dev/null 2>&1
    fi
  fi
  return 0
}
# br_event <event> <project> <cap-key> <reason> <detail> — ONE line per rung
#   transition, in the shape every later reader wants: a grep-able `EVENT
#   <name>` line in this lane's log and a fleet_event beat for the console.
#   A ladder whose transitions are only visible as prose is a ladder nobody can
#   count, and counting them is how the next "121 rebuilds, zero fix rounds"
#   gets noticed in a day rather than in a month.
br_event() {
  local ev="$1" p="$2" ck="$3" why="$4" detail="$5"
  say "EVENT $ev $p/$ck [$why] $detail"
  command -v bhw_event_ack >/dev/null 2>&1 && bhw_event_ack "$ev"
  [ -x "$H/bin/beat.sh" ] || return 0
  "$H/bin/beat.sh" "$(jq -nc --arg e "$ev" --arg p "$p" --arg k "$ck" --arg w "$why" \
      --arg d "$detail" --arg ts "$(STAMP)" \
      '{kind:"fleet_event",project:$p,rkey:("resolver:"+$p+"/"+$k),event:$e,reason:$w,detail:$d,ts:$ts}' 2>/dev/null)" \
    >/dev/null 2>&1 || true
  return 0
}

br_set_outcome() {
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg o "$3" --arg t "$(STAMP)" '.outcome=$o | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_set_field <project> <cap-key> <field> <value> — one scalar on the record.
# The rebuild rung uses it for `parked_url` (the PR it just closed, which the
# rebuild-outcome path needs later to move that row and name it in the comment)
# and for `rebuild_result` (the RESULT line the outcome was read from, so the
# abandon can quote it even when the evidence was a queue row rather than a
# directory). An empty value is written as "-", never as an empty string that a
# later reader would have to guess about.
# br_set_num <project> <cap-key> <field> <n> — the same, for a COUNTER.
#   br_set_field writes every value as a JSON string, and br_record's bump is
#   `.[$b] = ((.[$b] // 0) + 1)` — arithmetic, which dies on a string ("string
#   and number cannot be added") and takes the whole attempt record with it. So
#   a field any rung increments is reset through this one, with --argjson.
br_set_num() {
  local f cur v="${4:-0}"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --argjson v "$v" --arg t "$(STAMP)" \
        '.[$k]=$v | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}
br_set_field() {
  local f cur v="${4:-}"; [ -n "$v" ] || v="-"
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --arg v "$v" --arg t "$(STAMP)" \
        '.[$k]=$v | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_set_num <project> <cap-key> <field> <n> — the NUMERIC twin of br_set_field,
# for counters a later reader compares as a number (`enqueue_failures`). Written
# as a json number, never as a string: br_num reads either, but a counter that
# renders as "6" in the record is one more thing an operator has to think about.
br_set_num() {
  local f cur v="${4:-0}"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --argjson v "$v" --arg t "$(STAMP)" \
        '.[$k]=$v | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_seen_rebuild <project> <cap-key> <record-name> — remember a rebuild record
# whose outcome has been consumed, so a landed rebuild is recorded ONCE and not
# re-recorded on every tick until something else moves the ticket on.
br_seen_rebuild() {
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg n "$3" --arg t "$(STAMP)" \
        '.rebuild_seen = ((.rebuild_seen // []) + [$n] | unique) | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_json_edit <project> <cap-key> <jq-filter> [jq args…]
#   ONE jq write over the ticket's record, in br_record's shape: load, apply,
#   rewrite. A filter that fails leaves the file exactly as it was and answers
#   rc 1 — a half-applied record is how "stamped contested without a hold"
#   happens, so there is no path here that writes part of a change.
br_json_edit() {
  local p="$1" k="$2" filter="$3"; shift 3
  local f cur
  f=$(br_file "$p" "$k"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$p" "$k" | jq -c "$@" "$filter" 2>/dev/null) || return 1
  [ -n "$cur" ] || return 1
  br_save "$p" "$k" "$cur"
  return 0
}

