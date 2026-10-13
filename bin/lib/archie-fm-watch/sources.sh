#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-watch/sources.sh — BH-4586 (BH-4574.4): where the watch's
# findings come from. Sourced by bin/archie-fm-watch.sh, never run.
#
#   afw_alerts        the OPEN rows of the jobs-DB alerts table (new, triaged,
#                     parked), each read through afw_match. The lane raises no
#                     alert of its own: it reads the ones that exist.
#   afw_sweep_rescue  builds/*/RESULT REVIEW_BLOCKED (or ABANDONED_TIMEOUT with
#                     REAPED) that nobody rescued
#   afw_sweep_inode   this box's inode use (no detector exists for it)
#   afw_sweep_cron    a wired hub lane on main whose script is not in crontab
#   afw_sweep_pause   a project paused with work waiting
#   afw_sweep_owed    an OWED TO OPERATOR line in STATE.md past its expected-by
#   afw_sweep_metric  an active initiative whose last check was `unreadable`
#
# Every finding is one line appended to $AFW_FINDINGS (afw_emit). A read that
# fails is never "no findings": it logs and sets AFW_INCOMPLETE=1 (D9, D12).
# The root is ${HARNESS:-${H:-}} (D43).
# gh-rest: no-graphql

AFW_RESCUE_DIRS_MAX=500
AFW_ALERT_LIMIT=200

# afw_emit <class> <subject> <incident> <project> <host> <alert_id> <opened> <evidence-json>
afw_emit() {
  local ev="$8"
  # Tabs and newlines never reach the TSV: the evidence is compact JSON.
  ev=$(jq -c . <<<"$ev" 2>/dev/null) || ev="{}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" "$3" "${4:-hub}" \
    "${5:--}" "${6:--}" "${7:-0}" "$ev" >> "$AFW_FINDINGS"
}

# afw_project_ok <p> -> rc 0 when <p> is a fleet.conf project (AFW_PROJECTS).
afw_project_ok() {
  local x
  [ -n "$1" ] || return 1
  for x in ${AFW_PROJECTS:-}; do [ "$x" = "$1" ] && return 0; done
  return 1
}

# afw_project_of_repo <owner/repo> -> the fleet project whose repo it is (AFW_PROJECT_REPOS).
afw_project_of_repo() {
  awk -v s="$1" '$2 == s { print $1; exit }' <<<"${AFW_PROJECT_REPOS:-}"
}

# afw_match <alert-id> <line> -> the class on stdout, rc 0; rc 1 no class.
#   Ids are the ones the detectors' keyers produce (as_sanitize_id folds every
#   char outside [A-Za-z0-9_.-] to _; pipeline-health keys ph-<key>). Lines are
#   matched at their START only, so a line quoted inside another alert is not
#   that alert.
afw_match() {
  local id="$1" line="$2"
  case "$id" in
    stuck-work) printf build-stuck; return 0 ;;
    lane-reaper_*) printf review-unrescued; return 0 ;;
    disk-high-?*|disk-refuse-?*|ph-tmpfull_?*) printf disk; return 0 ;;
    ph-deployworkers_?*|ph-consolepagesdrift_hub) printf deploy-drift; return 0 ;;
    untriaged-digest_?*) printf triage-skip; return 0 ;;
    ph-costrollupstale_hub|ph-costrate_?*|ph-costratenoeval_?*|ph-overcap_?*|budget-stop_?*)
      printf cost-anomaly; return 0 ;;
    main-red-?*)
      if [[ $line =~ ^\[orchestrator/main-red\]\ [^\ ]+\ main\ is\ (STILL\ )?RED ]]; then printf main-red; return 0; fi
      return 1 ;;
  esac
  case "$line" in
    "[fly-idle] "*) printf pool-idle; return 0 ;;
    "[orchestrator/fleet-propagate] "*) printf cron-install; return 0 ;;
    "[orchestrator/cost-reconcile] "*|"[cost-reconcile] "*|"[gh-quota] "*) printf cost-anomaly; return 0 ;;
  esac
  if [[ $line =~ ^\[[A-Za-z0-9_.-]+\]\ CRONTAB\ (GAP|DRIFT|RENDER\ FAILED) ]]; then printf cron-install; return 0; fi
  if [[ $line =~ ^\[[a-z0-9-]+\]\ ticket\ \#[0-9]+\ untriaged\ \>1h ]] || [[ $line =~ ^UNTRIAGED\ \>1h:\ [a-z0-9-]+\ \# ]]; then
    printf triage-skip; return 0
  fi
  return 1
}

# afw_alert_finding <id> <box> <project> <state> <first_seen-iso> <line>
#   one open alert -> at most one finding.
afw_alert_finding() {
  local id="$1" box="$2" proj="$3" st="$4" fs="$5" line="$6" c opened age min need p subj inc host ev r dir x extra=""
  r=$(afw_root)
  c=$(afw_match "$id" "$line") || return 0
  [ -z "${AFW_ONLY_CLASS:-}" ] || [ "$AFW_ONLY_CLASS" = "$c" ] || return 0
  opened=""
  [ -z "$fs" ] || opened=$(date -u -d "$fs" +%s 2>/dev/null)
  [[ $opened =~ ^[0-9]+$ ]] || { afw_log "alert $id: first_seen '$fs' is unreadable; not a finding"; return 0; }
  age=$(( NOW - opened ))
  min=$(afw_setting archie.watch.alert_min_age_s) || return 0
  need=$min
  case "$c" in
    review-unrescued) need=$(afw_setting archie.watch.rescue_grace_s) || return 0 ;;
    cron-install) need=$(afw_setting archie.watch.cron_install_s) || return 0 ;;
  esac
  [ "$need" -ge "$min" ] || need=$min
  [ "$age" -ge "$need" ] || return 0
  p=hub; subj=$id; inc="$id@$opened"; host=""
  case "$c" in
    review-unrescued)
      local rest
      rest=${id#lane-reaper_}
      for x in ${AFW_PROJECTS:-}; do case "$rest" in "${x}_"*) p=$x; break ;; esac; done
      afw_project_ok "$p" || { afw_log "alert $id: no fleet project in it; not a finding"; return 0; }
      dir=""
      [[ $line =~ build\ lane\ in\ ([A-Za-z0-9._-]+) ]] && dir=${BASH_REMATCH[1]}
      if [ -n "$dir" ] && [ -n "$r" ]; then
        # The sweep and this alert name the same build: one incident, one row.
        [ -e "$r/builds/$dir/.review-rescued" ] && return 0
        inc=$dir
      fi
      subj=${dir:-$rest} ;;
    disk)
      case "$id" in
        disk-high-*) host=${id#disk-high-} ;;
        disk-refuse-*) host=${id#disk-refuse-} ;;
        ph-tmpfull_*) host=${id#ph-tmpfull_} ;;
      esac
      subj=$host ;;
    deploy-drift)
      case "$id" in
        ph-deployworkers_*)
          local run="" slug=""
          [[ $line =~ Deploy\ workers\ run\ ([0-9]+)\  ]] && run=${BASH_REMATCH[1]}
          [[ $line =~ https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/actions/runs/ ]] && slug=${BASH_REMATCH[1]}
          extra=$(jq -nc --arg r "$run" --arg s "$slug" '{run_id: $r} + (if $s == "" then {} else {repo: $s} end)')
          subj="deploy workers${slug:+ on $slug}" ;;
        *) subj="console pages" ;;
      esac ;;
    main-red)
      local slug
      slug=$(sed -nE 's|^\[orchestrator/main-red\] ([^ ]+) main is.*|\1|p' <<<"$line")
      [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && extra=$(jq -nc --arg s "$slug" '{repo: $s}')
      x=$(afw_project_of_repo "$slug"); [ -n "$x" ] && p=$x
      subj=${slug:-$id} ;;
    triage-skip)
      local tp=""
      case "$id" in
        untriaged-digest_*) tp=${id#untriaged-digest_}; tp=${tp%%_*} ;;
        *) [[ $line =~ ^\[([a-z0-9-]+)\]\ ticket ]] && tp=${BASH_REMATCH[1]}
           [[ $line =~ ^UNTRIAGED\ \>1h:\ ([a-z0-9-]+)\  ]] && tp=${BASH_REMATCH[1]} ;;
      esac
      # A board that is not in fleet.conf has no owning box: refused here, before
      # any row (the box would refuse run_triage for it anyway).
      afw_project_ok "$tp" || { afw_log "alert $id: '$tp' is not a fleet.conf project; not a finding"; return 0; }
      p=$tp; subj=$tp ;;
    cost-anomaly)
      local cp=""
      case "$id" in
        ph-costrate_*) cp=${id#ph-costrate_} ;;
        ph-overcap_*) cp=${id#ph-overcap_} ;;
        budget-stop_*) cp=${id#budget-stop_}; cp=${cp%%_*} ;;
      esac
      afw_project_ok "$cp" && p=$cp ;;
    cron-install)
      [[ $line =~ ^\[([A-Za-z0-9_.-]+)\]\ CRONTAB ]] && subj=${BASH_REMATCH[1]} ;;
  esac
  [ -n "$extra" ] || extra='{}'
  ev=$(jq -nc --arg id "$id" --arg st "$st" --arg fs "$fs" --arg b "$box" --arg pr "$proj" --arg l "${line:0:600}" \
    --argjson x "$extra" '{source: "alert", alert_id: $id, state: $st, first_seen: $fs, box: $b, alert_project: $pr, line: $l} + $x')
  afw_emit "$c" "$subj" "$inc" "$p" "$host" "$id" "$opened" "$ev"
}

# afw_alerts — every open alert (new, triaged, parked), at most
#   AFW_ALERT_LIMIT per state. A failed read means NO alert-fed finding this
#   tick (never "no alerts"); a truncated page is incomplete=1.
afw_alerts() {
  local st out rc all="" id box proj ast fs line
  command -v alerts_list >/dev/null 2>&1 || { afw_log "alerts_list is not loaded; no alert-fed finding this tick"; AFW_INCOMPLETE=1; return 0; }
  for st in new triaged parked; do
    rc=0; out=$(alerts_list --state "$st" --limit "$AFW_ALERT_LIMIT") || rc=$?
    if [ "$rc" != 0 ]; then
      afw_log "the open alerts (state $st) could not be read (rc=$rc http=${JOBS_HTTP:-none}); no alert-fed finding this tick"
      AFW_INCOMPLETE=1; return 0
    fi
    if grep -qx '#truncated' <<<"$out"; then
      afw_log "the $st alerts are a full page ($AFW_ALERT_LIMIT); only what was read is acted on"
      AFW_INCOMPLETE=1
    fi
    all+="$out"$'\n'
  done
  # id family box project state count first_seen last_seen claimed_by claimed_at
  # notified_at severity line: \x1f, not a tab, so an empty column stays a column.
  while IFS=$'\x1f' read -r id box proj ast fs line; do
    [ -n "$id" ] || continue
    afw_alert_finding "$id" "$box" "$proj" "$ast" "$fs" "$line"
  done < <(awk -F'\t' 'NF >= 13 && $1 != "#truncated" {
      l = $13; for (i = 14; i <= NF; i++) l = l "\t" $i
      printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n", $1, $3, $4, $5, $7, l }' <<<"$all")
}

# afw_sweep_rescue — a build whose review was never rescued: RESULT starts
#   REVIEW_BLOCKED (and has no verdict, review-rescue's own rule, unless it is a
#   test-tamper block), or ABANDONED_TIMEOUT with REAPED; no .review-rescued, no
#   .blocked-resolver-superseded; RESULT older than archie.watch.rescue_grace_s.
#   Bounded: dirs touched in the last AFW_RESCUE_LOOKBACK_H, at most 500.
afw_sweep_rescue() {
  local r grace lb d dirs first mt core proj ev
  r=$(afw_root); [ -n "$r" ] && [ -d "$r/builds" ] || return 0
  grace=$(afw_setting archie.watch.rescue_grace_s) || return 0
  lb=${AFW_RESCUE_LOOKBACK_H:-168}
  mapfile -t dirs < <(find "$r/builds" -mindepth 1 -maxdepth 1 -type d -newermt "@$(( NOW - lb * 3600 ))" 2>/dev/null \
    | head -n $((AFW_RESCUE_DIRS_MAX + 1)))
  if [ "${#dirs[@]}" -gt "$AFW_RESCUE_DIRS_MAX" ]; then
    afw_log "rescue sweep: more than $AFW_RESCUE_DIRS_MAX build dirs in ${lb}h; only $AFW_RESCUE_DIRS_MAX read"
    AFW_INCOMPLETE=1; dirs=("${dirs[@]:0:$AFW_RESCUE_DIRS_MAX}")
  fi
  for d in "${dirs[@]}"; do
    [ -f "$d/RESULT" ] || continue
    case "$d" in */.pool-*.tmp.*) continue ;; esac
    [ -e "$d/.review-rescued" ] && continue
    [ -e "$d/.blocked-resolver-superseded" ] && continue
    first=$(head -1 "$d/RESULT" 2>/dev/null)
    case "$first" in
      "REVIEW_BLOCKED test-tamper"*) ;;
      REVIEW_BLOCKED*)
        if command -v verdict_parse >/dev/null 2>&1 && verdict_parse -L "$d/review.md" >/dev/null 2>&1; then continue; fi ;;
      ABANDONED_TIMEOUT*) [ -e "$d/REAPED" ] || continue ;;
      *) continue ;;
    esac
    mt=$(stat -c %Y "$d/RESULT" 2>/dev/null) || continue
    [ $(( NOW - mt )) -ge "$grace" ] || continue
    core=$(basename "$d"); core=${core#pool-}
    proj=$("$r/bin/project-of.sh" --prefix "$core" 2>/dev/null) || proj=""
    afw_project_ok "$proj" || { afw_log "rescue sweep: $(basename "$d") names no fleet project; skipped"; continue; }
    ev=$(jq -nc --arg d "$(basename "$d")" --arg f "${first:0:200}" '{source: "sweep", sweep: "rescue", dir: $d, result: $f}')
    afw_emit review-unrescued "$(basename "$d")" "$(basename "$d")" "$proj" "" "" "$mt" "$ev"
  done
}

# afw_sweep_inode — `df -iP / /tmp` on this box. IUse% at or over
#   archie.watch.inode_pct is a finding, once per mount per UTC day.
afw_sweep_inode() {
  local pct out rows host m u ev
  pct=$(afw_setting archie.watch.inode_pct) || return 0
  host=${AFW_HOSTS%% *}; [ -n "$host" ] || host=hub
  out=$(df -iP / /tmp 2>/dev/null) || true
  rows=$(awk 'NR > 1 && NF >= 6 && $5 ~ /^([0-9]+%|-)$/ { print $5 "\t" $6 }' <<<"$out")
  if [ -z "$rows" ]; then afw_log "inode sweep: df -iP gave no reading; not a finding"; AFW_INCOMPLETE=1; return 0; fi
  while IFS=$'\t' read -r u m; do
    [ "$u" = - ] && continue
    u=${u%\%}
    [ "$u" -ge "$pct" ] || continue
    ev=$(jq -nc --arg m "$m" --argjson u "$u" --argjson t "$pct" --arg h "$host" \
      '{source: "sweep", sweep: "inode", mount: $m, iuse_pct: $u, threshold: $t, host: $h}')
    afw_emit disk "$host:$m inodes $u%" "$host:$m:$DAY" hub "$host" "" "$NOW" "$ev"
  done <<<"$rows"
}

# afw_sweep_cron — a lane on main (AFW_CO, the hub's checkout) that is wired,
#   runs on the hub, has its own cron/lanes/<NNN>-<id>.cron fragment whose
#   crontab body names its script, was added more than
#   archie.watch.cron_install_s ago, and whose script no crontab line names.
#   The fragment is what render-cron.sh puts in the hub's crontab, so it is the
#   expected set. .cadence is prose and is NOT: lanes that run "via" a wrapper
#   (batch-resolve, fly-pool, prebuild-repro) or "on demand (no cron line)"
#   (box-chat, greenfield) carry a cadence and have no line of their own.
# afw_fragment_names <checkout> <lane-id> <script> -> rc 0 when a
#   cron/lanes/<NNN>-<id>.cron fragment exists and one of its body lines (not a
#   comment, not a `# @` directive) names <script>.
afw_fragment_names() {
  local f
  for f in "$1"/cron/lanes/[0-9]*-"$2".cron; do
    [ -f "$f" ] || continue
    grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -qF -- "$3" && return 0
  done
  return 1
}

afw_sweep_cron() {
  local co ci ct rc id script f sha cts ev
  co=${AFW_CO:-}
  ci=$(afw_setting archie.watch.cron_install_s) || return 0
  if [ -z "$co" ] || ! git -C "$co" rev-parse --git-dir >/dev/null 2>&1; then
    afw_log "cron sweep: ${co:-<no checkout>} is not a git checkout; skipped"; AFW_INCOMPLETE=1; return 0
  fi
  rc=0; ct=$(crontab -l 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then afw_log "cron sweep: crontab -l failed (rc=$rc); skipped"; AFW_INCOMPLETE=1; return 0; fi
  while IFS=$'\t' read -r f id script; do
    [ -n "$id" ] && [ -n "$script" ] || continue
    case "$ct" in *"$script"*) continue ;; esac
    afw_fragment_names "$co" "$id" "$script" || continue
    read -r sha cts < <(git -C "$co" log --diff-filter=A --format='%H %ct' -1 -- "catalog/lanes.d/$(basename "$f")" 2>/dev/null)
    [[ ${sha:-} =~ ^[0-9a-f]{40}$ ]] && [[ ${cts:-} =~ ^[0-9]+$ ]] || continue
    [ $(( NOW - cts )) -ge "$ci" ] || continue
    ev=$(jq -nc --arg l "$id" --arg s "$script" --arg c "$sha" --argjson t "$cts" \
      '{source: "sweep", sweep: "cron", lane: $l, script: $s, added_in: $c, added_at: $t}')
    afw_emit cron-install "$id" "$id@$sha" hub "" "" "$cts" "$ev"
  done < <(jq -r 'select(.wired == true and ((.boxes // []) | index("hub")) != null
                  and ((.cadence // "") | type == "string" and length > 0)
                  and ((.script // "") | type == "string" and length > 0))
                | [input_filename, .id, .script] | @tsv' "$co"/catalog/lanes.d/*.json 2>/dev/null)
}

# afw_sweep_pause — a pause (builds or merges) older than
#   archie.watch.pause_waiting_s while work waits behind it: ready lines for the
#   project (rq_lines) or conductor rows in READY for its repo.
afw_sweep_pause() {
  local r pw pf p w row id scope created ct n slug ev subj proj
  r=$(afw_root); [ -n "$r" ] || return 0
  pw=$(afw_setting archie.watch.pause_waiting_s) || return 0
  pf="$r/state/pauses.json"
  [ -f "$pf" ] || return 0
  command -v pause_active >/dev/null 2>&1 || { afw_log "pause sweep: pause_active is not loaded; skipped"; return 0; }
  for p in ${AFW_PROJECTS:-}; do
    for w in builds merges; do
      PAUSE_NOW=$NOW pause_active "$p" "$w" || continue
      row=$(jq -r --arg p "$p" --arg w "$w" --argjson now "$NOW" '[.pauses[]
          | select((.scope == "fleet" or .scope == $p) and .what == $w and .ended_at == null)
          | select((try (.expires_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0) > $now)]
        | sort_by(.created_at) | first // empty | [(.id | tostring), .scope, (.created_at // "")] | @tsv' "$pf" 2>/dev/null)
      [ -n "$row" ] || continue
      IFS=$'\t' read -r id scope created <<<"$row"
      ct=""
      [ -z "$created" ] || ct=$(date -u -d "$created" +%s 2>/dev/null)
      [[ $ct =~ ^[0-9]+$ ]] || { afw_log "pause sweep: pause $id has no readable created_at; skipped"; continue; }
      [ $(( NOW - ct )) -ge "$pw" ] || continue
      n=0
      if [ "$w" = builds ]; then
        command -v rq_lines >/dev/null 2>&1 || { afw_log "pause sweep: rq_lines is not loaded; the builds queue is unread"; continue; }
        n=$(rq_lines "$r" "$p" 2>/dev/null | grep -c .)
      else
        slug=$(awk -v p="$p" '$1 == p { print $2; exit }' <<<"${AFW_PROJECT_REPOS:-}")
        [ -n "$slug" ] && command -v afq_rows_of >/dev/null 2>&1 \
          && n=$(afq_rows_of "$slug" | awk -F'\t' '$2 == "READY"' | grep -c .)
      fi
      [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
      proj=$p; subj="$p $w"
      [ "$scope" = fleet ] && { proj=hub; subj="fleet $w"; }
      ev=$(jq -nc --arg id "$id" --arg s "$scope" --arg w "$w" --arg c "$created" --arg p "$p" --argjson n "$n" \
        '{source: "sweep", sweep: "pause", pause_id: $id, scope: $s, what: $w, since: $c, project: $p, waiting: $n}')
      afw_emit pause-waiting "$subj paused since $created, $n waiting" "pause-$id" "$proj" "" "" "$ct" "$ev"
    done
  done
}

# afw_sweep_owed — the OWED TO OPERATOR lines in $AFW_STATE_MD (the hub
#   orchestrator's STATE.md) whose expected-by has passed (BH-4759, folded in
#   2026-10-05). A line counts when it names OWED TO OPERATOR itself, or when it
#   is a list item under a heading that does. Its expected-by is the first
#   `expected-by <ISO>` (or `expected by`) on the line; a line with none is not
#   known to be overdue and is skipped. The incident is the line's own text, so
#   each promise is one finding until it leaves the file. No file is one log
#   line, not a finding.
afw_sweep_owed() {
  local f="${AFW_STATE_MD:-}" line by ts ev
  [ -n "$f" ] || return 0
  [ -r "$f" ] || { afw_log "owed sweep: $f is not readable; skipped"; return 0; }
  while IFS= read -r line; do
    by=$(printf '%s' "$line" | grep -oiE 'expected[- ]by[: =]*[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?' | head -1 \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?')
    [ -n "$by" ] || continue
    ts=$(date -u -d "${by/T/ }" +%s 2>/dev/null)
    [[ $ts =~ ^[0-9]+$ ]] || continue
    [ "$ts" -lt "$NOW" ] || continue
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*[-*][[:space:]]*//' | cut -c1-400)
    ev=$(jq -nc --arg l "$line" --arg b "$by" --arg f "$f" '{source: "sweep", sweep: "owed", line: $l, expected_by: $b, file: $f}')
    afw_emit owed-overdue "$line" "$(afw_inc_key "owed:$line")" hub "" "" "$ts" "$ev"
  done < <(awk '
    /^#/ { sec = (toupper($0) ~ /OWED TO OPERATOR/); next }
    toupper($0) ~ /OWED TO OPERATOR/ { print; next }
    sec && /^[[:space:]]*[-*][[:space:]]/ { print }' "$f")
}

# afw_sweep_metric — an ACTIVE initiative (GET /api/initiatives, the archie
#   lane's table) whose last check was `unreadable`: its metric could not be
#   read, and bin/archie.sh makes no call on it. The incident is I<id>, so it
#   is ONE finding: the first tick records it and every later tick finds the
#   row (afw_handle never escalates a note). A 404 is a worker without the
#   route (no finding); any other failure is incomplete.
afw_sweep_metric() {
  local resp rc
  resp=$(_jobs_req GET "/api/initiatives?status=active&limit=100"); rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) afw_log "metric sweep: GET /api/initiatives failed (rc=$rc http=${JOBS_HTTP:-none})"; AFW_INCOMPLETE=1; return 0 ;;
  esac
  jq -e '.initiatives | type == "array"' <<<"$resp" >/dev/null 2>&1 \
    || { afw_log "metric sweep: /api/initiatives answered no list"; AFW_INCOMPLETE=1; return 0; }
  [ "$(jq -r '.truncated // false' <<<"$resp")" = true ] && { afw_log "metric sweep: more than 100 active initiatives; the rest are unread"; AFW_INCOMPLETE=1; }
  local id goal at ts ev
  while IFS=$'\t' read -r id goal at; do
    [[ $id =~ ^[0-9]+$ ]] || continue
    ts=""; [ -n "$at" ] && ts=$(date -u -d "$at" +%s 2>/dev/null)
    [[ $ts =~ ^[0-9]+$ ]] || ts=$NOW
    ev=$(jq -nc --arg i "$id" --arg g "$goal" --arg a "$at" '{source: "sweep", sweep: "metric", initiative: ("I" + $i), goal: $g, last_check_at: $a}')
    afw_emit metric-unreadable "I$id $goal" "I$id" hub "" "" "$ts" "$ev"
  done < <(jq -r '.initiatives[] | select(.last_check_status == "unreadable")
      | [(.id | tostring), ((.goal // "") | gsub("[\\t\\n]"; " ") | .[0:200]), (.last_check_at // "")] | @tsv' <<<"$resp" 2>/dev/null)
}

# afw_collect — alerts, then the four sweeps, into $AFW_FINDINGS; then one
#   line per class+incident (the same incident from an alert and a sweep is
#   one finding), narrowed to AFW_ONLY_CLASS when set.
afw_collect() {
  : > "$AFW_FINDINGS"
  afw_alerts
  case "${AFW_ONLY_CLASS:-review-unrescued}" in review-unrescued) afw_sweep_rescue ;; esac
  case "${AFW_ONLY_CLASS:-disk}" in disk) afw_sweep_inode ;; esac
  case "${AFW_ONLY_CLASS:-cron-install}" in cron-install) afw_sweep_cron ;; esac
  case "${AFW_ONLY_CLASS:-pause-waiting}" in pause-waiting) afw_sweep_pause ;; esac
  case "${AFW_ONLY_CLASS:-owed-overdue}" in owed-overdue) afw_sweep_owed ;; esac
  case "${AFW_ONLY_CLASS:-metric-unreadable}" in metric-unreadable) afw_sweep_metric ;; esac
  awk -F'\t' '!seen[$1 "\t" $3]++' "$AFW_FINDINGS" > "$AFW_FINDINGS.u" && mv "$AFW_FINDINGS.u" "$AFW_FINDINGS"
}
