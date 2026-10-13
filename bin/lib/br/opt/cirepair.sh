#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/cirepair.sh — Lane D (2026-09-24): a red CI gets at most
# BR_CI_REPAIR_ROUNDS repair rounds per PR head lineage, then the ticket is
# PARKED with one decision request instead of more rounds.
#
# WHY. A CI-red park (red-ci-twice, red-twice, queue-ejected-twice) climbed
# merge-main (mechanical), a regenerate merge (regen), an agent fix round, and
# then REBUILD FRESH up to three times: every rung another push and another CI
# run on a change CI had already refused twice. The practice this follows
# (Stripe's) caps CI iterations at two: after the second push still comes back
# red, a person or a narrower re-plan gets it, not a third round.
#
# WHAT COUNTS. A REPAIR ROUND is a rung whose own record line says it PUSHED a
# sha in answer to a CI-red park: `mechanical` ("… and pushed <sha>"), `regen`
# ("pushed <sha> over …"), `fix-round` ("pushed <sha> to …"). A rung that
# pushed nothing the lane saw is not a round: mechanical-failed, a mechanical
# that re-ran CI or queued a pool rebase, regen-noop, a fix round with no
# verified commit or "not pushed" (review of #2222, nit 2).
#
# THE LINEAGE IS THE PR (review of #2222, nit 1). The record is the TICKET's
# (br_cap_key), so it also holds the rounds of every earlier PR of that ticket.
# The module stamps the PR it counts for (`ci_lineage_url`) and the attempt
# index its lineage starts at (`ci_lineage_from`): a PR it has not seen before
# starts at the end of the record, and a `rebuild-fresh` always starts a new
# one. A record with NO stamp yet (every record at rollout) cannot say which
# PR its older attempts belong to, and the record is the ticket's: a second PR
# of the ticket opened without a rebuild-fresh would inherit the first PR's
# rounds and park on the first tick (review round 2 of #2222). So on an
# unstamped record only attempts whose own `url` is this PR count (br_record
# stores it when the caller hands one in; fix rounds do), after the last
# rebuild-fresh, and the stamp written then starts the lineage at the first
# such attempt, or at the end of the record when there is none.
#
# THE PARK, THEN AN AUTOMATIC RE-PLAN (policy, the operator 2026-09-24; the exception
# is written into guardrail 1, rules/topics/01-iron-guardrails.md). Nothing
# waits on a person: ONE comment on the PR naming this lineage's rounds and
# saying the ticket is re-planned automatically, the failing-CI evidence
# written to state/build-notes/<p>/<key>.md (KIND: ci-replan; the next build's
# plan stage reads it as a narrower re-plan brief, and bin/fly-pool.sh relays it
# to a pool machine), ONE fresh build of the ticket enqueued (br_enqueue_fresh,
# the PR is NOT closed), at most BR_CI_REPLAN_MAX (default 1) per ticket; once
# they are spent, or with the knob at 0, CI exhaustion is ABANDONED
# (br_abandon), the old rule, and the earlier parked PR is closed with it.
# When the re-plan's own PR exists, the parked PR is closed as superseded by it
# (br_ci_supersede_parked), so the ticket never has two live PRs.
# The park itself: outcome CI_PARKED scoped to this PR
# (ci_parked_rkey), one UNTRIAGED severity-warn beat, which bin/beat.sh spools
# for the deterministic warn digest (alert-digest.sh --warn-batch): no page, no
# LLM. A parked PR is a decision for later, not an emergency (the operator: minimal
# paging). It must not carry triaged:true: beat.sh routes only untriaged beats
# by severity and the console ignores severity, so a triaged warn paged at once
# (review round 2 of #2222). Never an ALERTS.log line either: that file feeds
# the LLM triage spool. A comment
# refused BR_CI_PARK_COMMENT_TRIES (3) times is not retried for ever: the park
# is recorded anyway and the beat says the PR could not be told.
#
# THE HOOK is br_opt_ci_cap_rung, called by br_one right after the carry and
# conflict hooks (bin/lib/br/opt/README.md): rc 0 = parked (or a refused
# comment counted) this tick, rc 3 = already parked (a terminal: no rung, no
# slot), anything else = the lane's own ladder, byte for byte.
# BR_CI_REPAIR_ROUNDS=0 (or BR_OPT_OFF naming cirepair) is the old ladder.
#
# Knob: BR_CI_REPAIR_ROUNDS on the blocked-resolver lane (catalog/lanes.d/
# blocked-resolver.json, default 2). Tests:
# tests/blocked-resolver-ci-repair-cap-test.sh.

BR_CI_PARK_COMMENT_TRIES=3

# br_ci_repair_cap -> the cap, a whole number; an unset or junk value is the
# registry default 2 (never "unbounded").
br_ci_repair_cap() {
  local c="${BR_CI_REPAIR_ROUNDS:-}"
  case "$c" in ''|*[!0-9]*) c=2 ;; esac
  printf '%s' "$c"
}

# br_ci_lineage_from <record-json> <pr-url> -> the attempt index this PR's
# lineage starts at (pure). See THE LINEAGE IS THE PR above.
br_ci_lineage_from() {
  printf '%s' "${1:-}" | jq -r --arg u "${2:-}" '
    (.attempts // []) as $a
    | (([range(0; $a | length) | select($a[.].action == "rebuild-fresh")] | last // -1) + 1) as $cut
    | ((.ci_lineage_url // "") | if . == "-" then "" else . end) as $su
    | ((.ci_lineage_from // "0") | tostring | tonumber? // 0) as $sf
    | if $su == "" then
        ([range($cut; $a | length) | select(($a[.].url // "") == $u)] | first // ($a | length))
      elif $su == $u then ([$cut, $sf] | max)
      else ($a | length) end' 2>/dev/null || printf '0'
}

# br_ci_lineage_stamped <record-json> -> rc 0 when the record carries a lineage
# stamp (pure).
br_ci_lineage_stamped() {
  case "$(printf '%s' "${1:-}" | jq -r '.ci_lineage_url // ""' 2>/dev/null)" in ''|-) return 1 ;; esac
  return 0
}

# br_ci_lineage_rounds <record-json> <from> [pr-url] -> the pushed CI repair
# attempts of this lineage, one JSON object a line (pure). With a url, only
# attempts whose own `url` is that PR (the unstamped-record case).
br_ci_lineage_rounds() {
  printf '%s' "${1:-}" | jq -c --argjson f "${2:-0}" --arg u "${3:-}" '
    (.attempts // [])[$f:][]
    | select($u == "" or (.url // "") == $u)
    | select((.reason // "") | test("^(red-ci-twice|red-twice|queue-ejected-twice|provenance-ci-red)"))
    | select(.action == "mechanical" or .action == "regen" or .action == "fix-round")
    | select((.detail // "") | test("(^|[^t] )pushed [0-9a-f]{4,}"))' 2>/dev/null
}

# br_ci_replan_max -> automatic narrower re-plans per ticket lineage before
# CI-repair exhaustion is ABANDONED (BR_CI_REPLAN_MAX, registry default 1;
# 0 = the old rule, ABANDONED at once). An unset or junk value is the default.
br_ci_replan_max() {
  local c="${BR_CI_REPLAN_MAX:-}"
  case "$c" in ''|*[!0-9]*) c=1 ;; esac
  printf '%s' "$((10#$c))"
}

# br_ci_replan_note <project> <ticket-key> <pr-url> <reason> <rounds> <cap> <round-lines>
#   The failing-CI evidence for the re-plan, in the resolver's carried-note
#   channel: state/build-notes/<p>/<key>.md, which bin/run-build.sh's plan stage
#   consumes once (and bin/fly-pool.sh relays to a pool machine). The first
#   line `KIND: ci-replan` is what makes the plan stage read it as a narrower
#   re-plan brief rather than an adjudication ruling.
br_ci_replan_note() {
  local p="$1" tkey="$2" url="$3" reason="$4" n="$5" cap="$6" lines="$7" d
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 1
  d="${NOTES:-$H/state/build-notes}/$p"; mkdir -p "$d" 2>/dev/null || return 1
  {
    printf 'KIND: ci-replan\n'
    printf 'PRIOR PR: %s (parked OPEN, CI still red)\n' "${url:--}"
    printf 'WHY IT PARKED: %s\n' "$reason"
    printf 'CI REPAIR ROUNDS THAT PUSHED A COMMIT: %s (cap %s). Each is below, with what it pushed:\n%s\n' "$n" "$cap" "$lines"
    printf 'RE-PLAN: the prior plan produced a change CI kept refusing. Plan a NARROWER change: the smallest slice of this ticket that can land green on its own, leaving the rest for a follow-up, and read the failing checks on the prior PR before choosing it. Do not repeat the prior approach unchanged.\n'
  } > "$d/$tkey.md.tmp" && mv -f "$d/$tkey.md.tmp" "$d/$tkey.md" || return 1
  # BH-5003: the ledger row too (bin/lib/build-note-db.sh), so a build on a
  # watcher box sees it. The file above is already the note; a failed put costs
  # the watcher boxes only.
  if command -v bn_put >/dev/null 2>&1 && ! bn_put "$p" "$tkey" "$d/$tkey.md"; then
    say "$p/$tkey [$reason]: build note NOT in the DB — only hub/pool builds will see it"
  fi
  return 0
}

# br_ci_replan_successor <project> <ticket-key> <parked-url> <since-epoch>
#   -> the newest PR url a build of this ticket reported (RESULT
#   `PR_CREATED <url>`) at or after the re-plan was enqueued, other than the
#   parked PR. The same build-record globs br_from_rebuilds reads for a
#   rebuild's outcome; a record this lane already superseded or abandoned is
#   never a successor. rc 1 = none yet.
br_ci_replan_successor() {
  local p="$1" key="$2" parked="$3" since="$4" d first u best="" bep=0 ep
  for d in "$H"/builds/pool-"$p"-"$key"-* "$H"/builds/fly-"$p"-"$key"-* "$H"/builds/"$p"-"$key"-*; do
    d="${d%/}"
    [ -d "$d" ] && [ -f "$d/RESULT" ] || continue
    [ -f "$d/.blocked-resolver-superseded" ] && continue
    [ -f "$d/.blocked-resolver-abandoned" ] && continue
    first=$(head -1 "$d/RESULT" 2>/dev/null)
    u=$(printf '%s' "$first" | sed -nE 's#^PR_CREATED[[:space:]]+(https://github\.com/[^[:space:]]+/pull/[0-9]+).*#\1#p')
    [ -n "$u" ] && [ "$u" != "$parked" ] || continue
    ep=$(date -u -r "$d/RESULT" +%s 2>/dev/null) || continue
    [ "$ep" -ge "$since" ] || continue
    [ "$ep" -ge "$bep" ] && { best="$u"; bep="$ep"; }
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# br_ci_head_is_ours <record-json> <head> — rc 0 when a recorded attempt of
#   this lane says it pushed this head (`pushed <sha>` in its detail, the short
#   sha a prefix of the full one). The harness-authored test: a commit identity
#   cannot tell, the fleet PAT and the operator share one login.
br_ci_head_is_ours() {
  printf '%s' "${1:-}" | jq -e --arg h "${2:-}" '
    [(.attempts // [])[] | (.detail // "") | scan("pushed ([0-9a-f]{4,40})") | .[0]]
    | any(. as $s | ($h | startswith($s)))' >/dev/null 2>&1
}

# br_ci_replan_floor <project> <ticket-key> -> how many automatic re-plans this
#   ticket has already carried, counted from the notes themselves (a relayed
#   `KIND: ci-replan` note on the hub, or one a build consumed into its record).
#   A `KIND: stale-replan` note (bin/lib/br/opt/stale.sh, BH-3935) counts too:
#   both ladders share BR_CI_REPLAN_MAX, so one ticket is never re-planned twice.
#   BH-5003: a note a WATCHER box consumed from its ledger row leaves the hub
#   file un-suffixed and no record here, so an un-suffixed hub note whose row is
#   `consumed` counts too, but only when the row is THIS note (bn_used), never
#   an earlier note's row.
br_ci_replan_floor() {
  local p="$1" key="$2" f n=0
  [ -n "$key" ] && [ "$key" != "-" ] || { printf 0; return 0; }
  f="${NOTES:-$H/state/build-notes}/$p/$key.md"
  if [ -f "$f" ] && [ "$(head -1 "$f" 2>/dev/null)" = "KIND: ci-replan" ] && command -v bn_used >/dev/null 2>&1 \
     && [ "$(bn_used "$p" "$key" "$f" 2>/dev/null)" = consumed ]; then
    n=$((n + 1))
  fi
  for f in "${NOTES:-$H/state/build-notes}/$p/$key.md.relayed-"* \
           "$H"/builds/pool-"$p"-"$key"-*/carried-note.md "$H"/builds/fly-"$p"-"$key"-*/carried-note.md \
           "$H"/builds/"$p"-"$key"-*/carried-note.md; do
    [ -f "$f" ] || continue
    case "$(head -1 "$f" 2>/dev/null)" in "KIND: ci-replan"|"KIND: stale-replan") n=$((n + 1)) ;; esac
  done
  printf '%s' "$n"
}

# br_ci_supersede_parked <p> <cap-key> <rkey> <reason> <url> <record> <ticket-key> <record-json>
#   The parked PR's end once its automatic re-plan has a PR of its own: the
#   rebuild-fresh close path (br_close_pr with the superseding comment, the
#   record's .blocked-resolver-superseded marker, br_row_closed `superseded`),
#   the conductor row moved to CLOSED, and outcome CI_SUPERSEDED so no later
#   tick closes anything again. rc 0 = acted this tick (closed, or deferred
#   because the close could not be made); rc 1 = no successor yet.
br_ci_supersede_parked() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" rec="$6" tkey="$7" st="$8"
  local at since new nn ckey crc=0
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 1
  at=$(printf '%s' "$st" | jq -r '[.attempts[]? | select(.action == "ci-replan")] | last | (.at // "")' 2>/dev/null)
  [ -n "$at" ] || return 1
  since=$(date -u -d "$at" +%s 2>/dev/null) || return 1
  new=$(br_ci_replan_successor "$p" "$tkey" "$url" "$since") || return 1
  nn="${new##*/}"
  # NEVER CLOSE A HUMAN FIX (review BLOCKER on #2222). The park comment invites
  # a push on this branch. The head is re-read now and must be the one parked
  # (ci_parked_head) AND one a recorded repair round of this lane pushed;
  # otherwise the PR is left open, said once per head.
  local ph cur hrc
  ph=$(printf '%s' "$st" | jq -r '.ci_parked_head // ""' 2>/dev/null)
  cur=$(br_pr_field "$url" '.head.sha' "pr head" 2>/dev/null); hrc=$?
  cur=$(printf '%s' "$cur" | tr 'A-F' 'a-f')
  if [ "$hrc" != 0 ] || [ -z "$cur" ]; then
    say "$p/$rkey [$reason]: the re-plan's PR $new exists but the parked PR's head could not be read — nothing closed, asked again next tick"
    return 0
  fi
  if [ -z "$ph" ] || [ "$ph" = "-" ] || [ "$cur" != "$ph" ]; then
    [ "$(printf '%s' "$st" | jq -r '.ci_supersede_left // ""' 2>/dev/null)" = "$cur" ] && return 0
    br_set_field "$p" "$ck" ci_supersede_left "$cur" >/dev/null 2>&1 || true
    say "$p/$rkey [$reason]: NOT superseded: its head moved since the park (${ph:0:12} -> ${cur:0:12}) — someone pushed to it, so it is left OPEN beside the re-plan's $new"
    return 0
  fi
  if ! br_ci_head_is_ours "$st" "$cur"; then
    [ "$(printf '%s' "$st" | jq -r '.ci_supersede_left // ""' 2>/dev/null)" = "$cur" ] && return 0
    br_set_field "$p" "$ck" ci_supersede_left "$cur" >/dev/null 2>&1 || true
    say "$p/$rkey [$reason]: NOT superseded: its head ${cur:0:12} is not one this lane pushed (no recorded repair round names it) — left OPEN beside the re-plan's $new"
    return 0
  fi
  if [ "${OBSERVE:-0}" = 1 ]; then say "$p/$rkey [$reason]: WOULD close the parked PR — superseded by #$nn (narrower re-plan) — observe mode"; return 0; fi
  br_close_pr "$url" "Superseded by #$nn (narrower re-plan): $new. This PR was parked after its CI repair rounds ran out, and the ticket's automatic narrower re-plan now has its own PR, so this one is closed unmerged. The branch is left in place." || crc=$?
  if [ "$crc" = 3 ]; then
    [ "$(printf '%s' "$st" | jq -r '.ci_supersede_left // ""' 2>/dev/null)" = "$cur" ] && return 0
    br_set_field "$p" "$ck" ci_supersede_left "$cur" >/dev/null 2>&1 || true
    say "$p/$rkey [$reason]: NOT superseded: $url is an external author's PR — left OPEN for the author beside the re-plan's $new, said once per head"
    return 0
  fi
  if [ "$crc" != 0 ]; then
    say "$p/$rkey [$reason]: the re-plan's PR $new exists but the parked PR could not be closed this tick — retried next tick"
    return 0
  fi
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && { : > "$rec/.blocked-resolver-superseded"; touch "$rec/COMMENTED" 2>/dev/null; }
  br_set_outcome "$p" "$ck" CI_SUPERSEDED || say "$p/$rkey [$reason]: superseded, but the outcome could not be written — the next tick finds the PR closed and closes nothing"
  br_set_field "$p" "$ck" ci_superseded_by "$new" >/dev/null 2>&1 || true
  br_record "$p" "$ck" ci-park-superseded "$reason" "closed unmerged: superseded by $new (narrower re-plan)"
  br_row_closed "$p" "$tkey" "$rec" "$url" superseded "closed unmerged by blocked-resolver (CI park); superseded by $new (narrower re-plan)" "$reason"
  ckey=$(mc_slug_of_url "$url" 2>/dev/null)
  [ -n "$ckey" ] && command -v mc_transition >/dev/null 2>&1 \
    && mc_transition "$ckey#$(mc_num_of_url "$url")" CLOSED "blocked-resolver: superseded by $new (narrower re-plan)" "-" "-" "$url" "-" "-" "${rec:--}" >/dev/null 2>&1
  say "$p/$rkey [$reason]: CI park SUPERSEDED — closed $url, superseded by $new (narrower re-plan)"
  return 0
}

# br_ci_park_beat <project> <rkey> <line> — the one untriaged warn beat (digest).
br_ci_park_beat() {
  [ -x "$H/bin/beat.sh" ] || return 0
  "$H/bin/beat.sh" "$(jq -nc --arg p "$1" --arg akey "resolver-ci-parked:$1:$2" --arg l "$3" \
    '{kind:"fleet_alert",project:$p,severity:"warn",akey:$akey,line:$l}')" >/dev/null 2>&1
  return 0
}

br_opt_ci_cap_rung() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="${6:--}"
  local cap ck st from rounds n lines body line tries told onlyurl
  command -v br_ladder_class >/dev/null 2>&1 && [ "$(br_ladder_class "$reason")" = ci-red ] || return 1
  cap=$(br_ci_repair_cap); [ "$cap" -gt 0 ] || return 1
  ck=$(br_cap_key "$p" "$rkey" "$tkey"); st=$(br_load "$p" "$ck")
  onlyurl=""; br_ci_lineage_stamped "$st" || onlyurl="${url:-}"
  from=$(br_ci_lineage_from "$st" "$url"); case "$from" in ''|*[!0-9]*) from=0 ;; esac
  # Stamp the PR this lineage belongs to (only when it changed), so the next
  # PR of this ticket starts from where this one ended.
  if [ "$(printf '%s' "$st" | jq -r '.ci_lineage_url // ""' 2>/dev/null)" != "$url" ] \
     || [ "$(printf '%s' "$st" | jq -r '.ci_lineage_from // ""' 2>/dev/null)" != "$from" ]; then
    br_set_field "$p" "$ck" ci_lineage_url "$url" >/dev/null 2>&1 || true
    br_set_field "$p" "$ck" ci_lineage_from "$from" >/dev/null 2>&1 || true
  fi
  rounds=$(br_ci_lineage_rounds "$st" "$from" "$onlyurl")
  n=$(printf '%s' "$rounds" | grep -c . || true); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  # ALREADY PARKED: a terminal while the rounds still reach the cap. A cap
  # raised above them since (a settings edit, no deploy) LIFTS the park and the
  # lane's own ladder runs; nothing is posted (lead LOW 4 on #2222).
  # A PARK ITS RE-PLAN SUPERSEDED is a terminal for that PR, whatever the cap.
  if [ "$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)" = CI_SUPERSEDED ]; then
    case "$(printf '%s' "$st" | jq -r '.ci_parked_rkey // ""' 2>/dev/null)" in "$rkey") return 3 ;; esac
  fi
  if [ "$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)" = CI_PARKED ]; then
    case "$(printf '%s' "$st" | jq -r '.ci_parked_rkey // ""' 2>/dev/null)" in
      "$rkey")
        if [ "$n" -ge "$cap" ]; then
          # The re-plan's own PR, once it exists (opened or already merged),
          # supersedes this one: the ticket never has two live PRs.
          br_ci_supersede_parked "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "$st" && return 0
          return 3
        fi
        if [ "${OBSERVE:-0}" = 1 ]; then
          say "$p/$rkey [$reason]: WOULD lift the CI park — $n round(s) is under the cap BR_CI_REPAIR_ROUNDS=$cap now — observe mode"; return 0
        fi
        br_set_outcome "$p" "$ck" "" || { say "$p/$rkey [$reason]: the CI park is under the raised cap ($n/$cap) but the outcome could not be cleared — still parked this tick"; return 3; }
        br_set_field "$p" "$ck" ci_parked_rkey "-" >/dev/null 2>&1 || true
        br_record "$p" "$ck" ci-park-lifted "$reason" "$n pushed repair round(s) is under the cap BR_CI_REPAIR_ROUNDS=$cap now; the ladder resumes"
        say "$p/$rkey [$reason]: CI park LIFTED — $n round(s) is under the raised cap BR_CI_REPAIR_ROUNDS=$cap; the lane's own ladder runs"
        return 1 ;;
    esac
  fi
  [ "$n" -ge "$cap" ] || return 1
  # PARK, THEN AUTO RE-PLAN (policy, the operator 2026-09-24; rules/topics/
  # 01-iron-guardrails.md). The ticket gets BR_CI_REPLAN_MAX automatic narrower
  # re-plans per lineage; once they are spent (or with the knob at 0) CI-repair
  # exhaustion is ABANDONED, the old rule.
  local rmax used why brc pu replanned=0 rwhy="" erc
  rmax=$(br_ci_replan_max)
  used=$(printf '%s' "$st" | jq -r '(.ci_replans // "0") | tostring | tonumber? // 0' 2>/dev/null); case "$used" in ''|*[!0-9]*) used=0 ;; esac
  # WIPE-RESISTANT (review nit): the re-plan notes this ticket already carried
  # are a floor under the counter, so a reset record buys no extra re-plan.
  local floor; floor=$(br_ci_replan_floor "$p" "$tkey")
  [ "${floor:-0}" -gt "$used" ] && used=$floor
  if [ "$rmax" -eq 0 ] || [ "$used" -ge "$rmax" ]; then
    why="CI stayed red after $n pushed repair round(s) on this PR (cap BR_CI_REPAIR_ROUNDS=$cap)"
    [ "$used" -gt 0 ] && why="$why, after $used automatic narrower re-plan(s) of the ticket (BR_CI_REPLAN_MAX=$rmax)"
    [ "$rmax" -eq 0 ] && why="$why; automatic re-plan is off (BR_CI_REPLAN_MAX=0)"
    if [ "${OBSERVE:-0}" = 1 ]; then say "$p/$rkey [$reason]: WOULD abandon — $why — observe mode"; return 0; fi
    br_abandon "$p" "$ck" "$reason" "$url" "$rec" "$why" "$tkey"; brc=$?
    # The PR the first park left open is superseded for good now: close it too.
    # Only on rc 0, which means closed and ABANDONED recorded: rc 3 is an
    # outsider's PR left for its author (BH-4667), and 75 is a deferred close.
    pu=$(printf '%s' "$st" | jq -r '.ci_parked_url // ""' 2>/dev/null)
    if [ "$brc" = 0 ] && [ -n "$pu" ] && [ "$pu" != "-" ] && [ "$pu" != "$url" ]; then
      br_close_pr "$pu" "Closed by \`bin/blocked-resolver.sh\`: this PR was parked CI-red and the ticket's automatic re-plan ($url) ran out of CI rounds too, so the ticket is ABANDONED." >/dev/null 2>&1 \
        || say "$p/$rkey [$reason]: the earlier parked PR $pu could not be closed — close it by hand"
    fi
    return 0
  fi
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD park and re-plan the ticket narrower — CI is red after $n pushed repair round(s) on this PR (cap BR_CI_REPAIR_ROUNDS=$cap) — observe mode"
    return 0
  fi
  lines=$(printf '%s\n' "$rounds" | jq -r 'select(.) | "- \(.at) \(.action): \(.detail)"' 2>/dev/null)
  body="CI is still red on this branch after $n repair round(s) that each pushed a new commit, and $cap is the cap, so I stopped repairing it here. The harness now starts a narrower re-plan of the ticket automatically, with these rounds as its evidence. This PR stays open and nothing was closed. The rounds on this PR:

$lines

No action is needed. A push on this branch still gets fresh CI, and a green head merges the usual way."
  told=1
  # PENDING BEFORE THE POST (lead MEDIUM 3 on #2222). The comment goes out
  # before the outcome is written; if that write fails, the marker is what stops
  # the next tick commenting again: a tick that finds it for this PR retries the
  # outcome write only. No marker written = nothing posted this tick.
  if [ "$(printf '%s' "$st" | jq -r '.ci_park_pending // ""' 2>/dev/null)" = "$rkey" ]; then
    say "$p/$rkey [$reason]: the park comment was posted on an earlier tick — finishing the park, no second comment"
  elif ! br_set_field "$p" "$ck" ci_park_pending "$rkey" >/dev/null 2>&1; then
    say "$p/$rkey [$reason]: CI repair cap reached ($n/$cap) but the pending marker could not be written to $(br_file "$p" "$ck") — nothing posted, retried next tick"
    return 0
  elif ! br_pr_comment "$url" "$body" >/dev/null 2>&1; then
    br_set_field "$p" "$ck" ci_park_pending "-" >/dev/null 2>&1 || true
    tries=$(( $(printf '%s' "$st" | jq -r '(.ci_park_refused // "0") | tostring | tonumber? // 0' 2>/dev/null) + 1 ))
    br_set_field "$p" "$ck" ci_park_refused "$tries" >/dev/null 2>&1 || true
    if [ "$tries" -lt "$BR_CI_PARK_COMMENT_TRIES" ]; then
      # D9: a refused send is never recorded as a park; the next tick tries again.
      say "$p/$rkey [$reason]: CI repair cap reached ($n/$cap) but the park comment was REFUSED on ${url:--no url} (try $tries of $BR_CI_PARK_COMMENT_TRIES) — nothing recorded, retried next tick"
      return 0
    fi
    told=0
  fi
  # THE RE-PLAN, EXACTLY ONCE PER PARK: the note first (the next build's plan
  # stage consumes it; bin/fly-pool.sh relays it to a pool machine), then the
  # enqueue, then the stamp that makes a later tick skip both. An enqueue that
  # could not be made THIS time (rc 1) leaves the pending marker, so the next
  # tick finishes the park without a second comment; a deterministic refusal
  # (rc 2/4: no ticket key, a board miss) parks without a re-plan and says so.
  if [ "$(printf '%s' "$st" | jq -r '.ci_replan_rkey // ""' 2>/dev/null)" = "$rkey" ]; then
    replanned=1
  elif [ -z "$tkey" ] || [ "$tkey" = "-" ]; then
    # NO TICKET KEY: nothing can be re-planned, on this tick or any other, so it
    # is a park without a re-plan (the rc 2/4 arm below), never a retry loop.
    rwhy="no ticket key could be derived for this PR, so no re-plan could be enqueued"
  else
    br_ci_replan_note "$p" "$tkey" "$url" "$reason" "$n" "$cap" "$lines" \
      || { say "$p/$rkey [$reason]: the re-plan note could not be written — nothing enqueued, retried next tick"; return 0; }
    erc=0
    br_enqueue_fresh "$p" "$tkey" "$(br_num "$st" rebuilds)" "ci-replan: $n red CI round(s) on ${url:--}" "$rec" "$rkey" "$url" || erc=$?
    case "$erc" in
      0|3) replanned=1
           br_set_field "$p" "$ck" ci_replan_rkey "$rkey" >/dev/null 2>&1 || true
           br_set_field "$p" "$ck" ci_replans "$((used + 1))" >/dev/null 2>&1 || true
           br_record "$p" "$ck" ci-replan "$reason" "narrower re-plan $((used + 1)) of $rmax enqueued (job ${BR_JOB_ID:-already queued}) with the failing-CI evidence of ${url:--}" rebuilds "$url" ;;
      2|4) rwhy="the re-plan could not be enqueued (${BR_ENQUEUE_WHY:-rc $erc}), so this is a park without one" ;;
      *) say "$p/$rkey [$reason]: CI repair cap reached but the re-plan could not be enqueued this tick (${BR_ENQUEUE_WHY:-rc $erc}) — retried next tick"
         return 0 ;;
    esac
  fi
  if ! br_set_outcome "$p" "$ck" CI_PARKED; then
    say "$p/$rkey [$reason]: parked, but the outcome could not be written to $(br_file "$p" "$ck") — the pending marker holds the comment; the next tick writes the outcome only"
    return 0
  fi
  br_set_field "$p" "$ck" ci_parked_rkey "$rkey" >/dev/null 2>&1 || true
  br_set_field "$p" "$ck" ci_parked_url "${url:--}" >/dev/null 2>&1 || true
  # THE HEAD IT PARKED, so the supersede can tell a human push afterwards.
  local phead; phead=$(br_pr_field "$url" '.head.sha' "pr head" 2>/dev/null) || phead=""
  br_set_field "$p" "$ck" ci_parked_head "$(printf '%s' "${phead:--}" | tr 'A-F' 'a-f')" >/dev/null 2>&1 || true
  br_set_field "$p" "$ck" ci_park_pending "-" >/dev/null 2>&1 || true
  local rp way
  if [ "$replanned" = 1 ]; then
    rp="A narrower re-plan enqueued automatically (re-plan $((used + 1)) of BR_CI_REPLAN_MAX=$rmax) with this PR's failing-CI evidence; no human needed. If the re-plan's PR also runs out of CI rounds, the ticket is ABANDONED."
  else
    rp="No re-plan: $rwhy."
  fi
  way="To re-offer this PR instead: set .outcome to \"\" in $(br_file "$p" "$ck"), or raise BR_CI_REPAIR_ROUNDS above $n (a park under the cap lifts itself on the next tick)."
  if [ "$told" = 1 ]; then
    br_record "$p" "$ck" ci-parked "$reason" "CI red after $n pushed repair round(s) on this PR (cap $cap); one comment posted, PR left open; $([ "$replanned" = 1 ] && echo "narrower re-plan enqueued" || echo "no re-plan: $rwhy")"
    say "$p/$rkey [$reason]: CI_PARKED — $n pushed repair round(s) did not turn CI green (cap BR_CI_REPAIR_ROUNDS=$cap); PR open and commented; $([ "$replanned" = 1 ] && echo "narrower re-plan enqueued" || echo "no re-plan: $rwhy")"
    line="[blocked-resolver] CI_PARKED $p/$rkey ($reason): CI stayed red after $n pushed repair round(s) on this PR (cap BR_CI_REPAIR_ROUNDS=$cap). The PR is OPEN: ${url:--no url}. $rp $way This PR's rounds:
$lines"
  else
    br_record "$p" "$ck" ci-parked "$reason" "CI red after $n pushed repair round(s) on this PR (cap $cap); the PR could not be commented ($BR_CI_PARK_COMMENT_TRIES refused posts), PR left open; $([ "$replanned" = 1 ] && echo "narrower re-plan enqueued" || echo "no re-plan: $rwhy")"
    say "$p/$rkey [$reason]: CI_PARKED — cap reached and the PR comment was refused $BR_CI_PARK_COMMENT_TRIES times; parked without telling the PR"
    line="[blocked-resolver] CI_PARKED $p/$rkey ($reason): CI stayed red after $n pushed repair round(s) on this PR (cap BR_CI_REPAIR_ROUNDS=$cap), and the PR could not be commented ($BR_CI_PARK_COMMENT_TRIES refused posts): ${url:--no url}. $rp $way This PR's rounds:
$lines"
  fi
  br_ci_park_beat "$p" "$rkey" "$line"
  return 0
}
