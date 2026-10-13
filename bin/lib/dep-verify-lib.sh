#!/bin/bash
# bin/lib/dep-verify-lib.sh — the shared vocabulary of "is this Blocked-by line
# a fact about the code, or a preference the author typed once".
#
# WHY A LIB (the operator, 2026-09-14). `Blocked-by: #N` has been an ORDER since the day
# bin/unblocked-children.sh learned to read it: the child waits until #N closes,
# or (since STACKABLE) until #N has an open PR to stack on. The graph is written
# by hand, once, by whoever filed the split — and it over-declares. Tonight's
# project-5 wave #666-#678 declares five levels where several children (the
# brain map off #669, the lifecycle rollup off #671) share no files with their
# parent at all and could have built on main from the first minute. the operator, 13:4xZ,
# on being told the wave runs only as wide as its hand-written Blocked-by lines:
# "how do we do that by default?" — so the harness widens the wave itself, by
# CHECKING the claim instead of obeying it.
#
# Three callers have to agree on the same facts for that to be safe — whether
# the check is armed, where a verdict is cached, and what "these two file lists
# are disjoint" means — and a second opinion on the last one is a child built on
# main that conflicts with its parent at merge time. So they are functions here
# and bin/dep-verify.sh, bin/unblocked-children.sh and bin/preplan-candidates.sh
# read them rather than each growing their own answer.
#
# Sourced, never executed. Safe under `set -u`. Nothing here writes, logs or
# calls GitHub: every function answers a question and the CALLER decides what
# that means.

# _dep_env <harness> <VAR> <default> -> the value
#   Environment first, then env/global.env, then the default. READS the env file
#   rather than sourcing it, the same way bin/lib/preplan-lib.sh:_preplan_env
#   does and for the same reason: a reporter answering a yes/no question must
#   never inherit a box's secrets to answer it.
_dep_env() {
  local h="${1:-}" var="${2:-}" def="${3:-}" v=""
  eval "v=\${$var:-}"
  if [ -z "$v" ] && [ -n "$h" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

# _dep_root -> $HARNESS, else $H, else nothing (BH-2613). A [harness] argument
# wins over it. With no root every switch and knob reads its default, which is
# what an unreadable root answers, and no cached verdict can be found.
_dep_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# dep_verify_on [harness] -> 1 | 0     (DEFAULT 1 — verification is ON)
#
# THE KILL FLAG. 0 puts bin/unblocked-children.sh and bin/preplan-candidates.sh
# back to what they do today, byte for byte: a Blocked-by line is obeyed, the
# `blocked` pre-plan class does not exist, and no verdict is ever asked for.
# The dep-verify-off switch is honoured beside the env var because an operator
# killing this at 3am should not have to edit env/global.env on every box
# (BH-2435: the settings row switch.dep-verify-off[.<box>], then
# flags/dep-verify-off; read in a subshell through ls_isolated, as
# builder_direct_on does).
dep_verify_on() {
  local h="${1:-$(_dep_root)}" v
  if [ -n "$h" ] && ( . "$h/bin/lib/lane-switch.sh" 2>/dev/null || ls_isolated() { [ -f "$h/flags/$2" ]; }
       HARNESS="$h" ls_isolated lane_switch dep-verify-off file ); then printf '0\n'; return 0; fi
  v=$(_dep_env "$h" DEP_VERIFY 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# dep_verify_dry [harness] -> 1 | 0    (DEFAULT 0)
#   DEP_VERIFY_DRY_RUN=1 prints the verdict and writes NOTHING — no cache row, no
#   issue comment. It is how a verdict is inspected before it is trusted.
dep_verify_dry() {
  local h="${1:-$(_dep_root)}" v
  v=$(_dep_env "$h" DEP_VERIFY_DRY_RUN 0)
  case "$v" in 1|yes|on|true) printf '1\n' ;; *) printf '0\n' ;; esac
}

# dep_unknown_mode [harness] -> soft | hard    (DEFAULT soft)
#
# WHAT AN UNKNOWN PAIR DOES TO THE CHILD. dep-verify.sh answers UNKNOWN when it
# has no evidence — no pre-plan for the child yet, no DEPENDS: line, no file
# list for the blocker — and until 2026-09-16 every caller obeyed UNKNOWN like
# HARD: the child waited. On project-5 at 05:04Z that held 22 of 49 open
# tickets behind parents nobody had pre-planned, with the Fly pool already at
# 0/unlimited. the operator: "There should be no cap, let's remove the cap." So the
# default is `soft`: an UNKNOWN pair is treated exactly like SOFT and the child
# is released to build on the default branch now; a real overlap that the
# missing evidence would have caught is resolved by the conductor's self-rebase
# at merge time. `hard` is the pre-2026-09-16 behaviour, kept as the knob's
# other setting for a box that would rather wait than rebase. HARD verdicts —
# pairs the evidence actually calls hard — are untouched by either setting.
dep_unknown_mode() {
  local h="${1:-$(_dep_root)}" v
  v=$(_dep_env "$h" DEP_UNKNOWN_MODE soft)
  case "$v" in hard|HARD|strict|1) printf 'hard\n' ;; *) printf 'soft\n' ;; esac
}

# dep_cache_dir <harness> <project>  -> state/dep-verify/<project>
# dep_cache_file <harness> <project> <child> <blocker>
#   One file per (child, blocker) pair, holding the evidence fingerprint and the
#   DEFINITE verdict it produced (bin/dep-verify.sh never caches an UNKNOWN — a
#   non-answer written down is a transient outage frozen into the graph). No
#   existence check: the writer needs the name first. An empty root prints
#   nothing, never a /state path (BH-2613).
dep_cache_dir()  { [ -n "${1:-}" ] || return 0; printf '%s/state/dep-verify/%s\n' "$1" "${2:-}"; }
dep_cache_file() { [ -n "${1:-}" ] || return 0; printf '%s/state/dep-verify/%s/%s-%s\n' "$1" "${2:-}" "${3:-}" "${4:-}"; }

# dep_repo_for <harness> <project> -> the GitHub slug whose issues carry this
#   project's Blocked-by lines, or nothing.
#
# The same mapping bin/unblocked-children.sh resolves for itself: GH_ISSUES_REPO
# wins, then any fleet.conf project whose board prefix is "-"
# (bin/load-project.sh onboards GitHub-Issues boards that way). In-app
# boards have no Blocked-by convention, so they resolve to nothing and every
# caller here then does nothing.
dep_repo_for() {
  local h="${1:-}" p="${2:-}" r="${GH_ISSUES_REPO:-}" bp
  if [ -z "$r" ]; then
    # project-5 and project-6 are board-prefix "-" rows too: their literal
    # slugs are gone (BH-4080) and fleet.conf column 2 answers for them.
    bp=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null || true)
    [ "$bp" = "-" ] && r=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null || true)
  fi
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

# dep_norm <infile> <outfile> -> the path list, normalised
#
# THE NORMALISATION IS bin/plan-overlap.sh's: strip a leading `./`, drop blanks
# and a trailing slash, sort -u. Nothing else. The EXCLUSION list that
# bin/planned-files.sh applies (only paths under src/prisma/scripts/… count, no
# bare two-segment directory scopes) is already baked into the child's
# planned-files.txt, because that file IS planned-files.sh output — and it is
# deliberately NOT applied to the blocker's real changed-file list. Every path
# that list excludes is a path a plan's file list can never name, so applying it
# there could only ever shrink the blocker's set, and a smaller blocker set can
# only turn a HARD into a SOFT. This check fails closed; it does not shrink.
# THE `SOURCE:` HEADER IS DROPPED HERE (BH-499) and nowhere else, because every
# reader of a planned-files list goes through this function. bin/planned-files-
# cheap.sh writes which tier produced its list as the file's first line, and a
# blocker's own pre-plan list can be one of those too — left in, it counts as a
# path, inflates every cheap list's size by one, and sits in the overlap
# comparison forever as a file nobody can find.
dep_norm() {
  local in="${1:-}" out="${2:-}"
  [ -r "$in" ] || { : > "$out"; return 1; }
  sed -e 's|^\./||' -e 's|/$||' -e 's/[[:space:]]*$//' "$in" \
    | grep -viE '^SOURCE:[[:space:]]*' | grep -v '^[[:space:]]*$' | sort -u > "$out"
  [ -s "$out" ]
}

# dep_list_source <planned-files.txt> -> the tier that produced it, or nothing
#   The header bin/planned-files-cheap.sh writes: `SOURCE: ticket-body`,
#   `SOURCE: ticket-body+codegraph`, `SOURCE: model-floor`. A list written by
#   bin/planned-files.sh out of a real plan.md has no header at all, and that
#   absence is meaningful — see bin/dep-verify.sh's closing block.
dep_list_source() {
  local f="${1:-}"
  [ -s "$f" ] || return 1
  sed -n '1s/^SOURCE:[[:space:]]*//p' "$f" | head -1 | tr -d '\r'
}

# dep_body_has_hard_marker <issue-body-file> -> rc 0 when the body says, ANYWHERE
#   in it, that this slice sits on top of something.
#
# WIDER THAN dep_declared_hard ON PURPOSE. That one asks "did the author declare
# THIS blocker hard", and it is the escape hatch: it answers the question being
# verified. This one asks "did the author make that kind of statement at all",
# and it gates a much weaker inference — the BH-499 path, where a deterministic
# file list stands in for a `DEPENDS:` line nobody was asked to write. An author
# who wrote `Needs: #12` on this ticket has told us the slice is not free-
# standing, and inferring independence from a list they never wrote, on a
# different blocker, is exactly the wrong direction to be confident in.
#
# EVERY BLOCKER OF THE LINE COUNTS (BH-515): a `(hard)` in second position
# on `Blocked-by: #A, #B (hard)` is the same statement as one in first.
dep_body_has_hard_marker() {
  local f="${1:-}"
  [ -r "$f" ] || return 1
  grep -qiE "^[[:space:]>*_#-]*blocked[- ]by\b.*#[0-9]+[[:space:]]*\((hard|blocking)\)" "$f" && return 0
  grep -qiE "^[[:space:]>*_#-]*needs\b[^#]*#[0-9]" "$f" && return 0
  return 1
}

# dep_overlap <list-a> <list-b> -> the first colliding pairs, or nothing
#
# THE OVERLAP RULE IS bin/conflict-check.sh's, transcribed by
# bin/plan-overlap.sh and transcribed again here for the same reason both of
# those say out loud: two plans conflict when any planned path of one equals, or
# is a path-prefix of, a planned path of the other (file == file, dir contains
# file). Three readers of one rule; a fourth spelling of it is a child built on
# main that conflicts with its parent at merge time.
#
# ONE PRUNE BEFORE THE COMPARISON (2026-09-14). A pre-plan's file list names
# BOTH a directory and the file it adds under it — project-5 TK-667's is
# `prisma/migrations/manual` AND `prisma/migrations/manual/2026-09-14-TK-667-
# team-chart-max-members.sql` — because "I create a migration" reads as two
# claims to whoever wrote the plan. Left in, the bare directory collides with
# every sibling's migration, and #669's own new .sql file was reported as
# overlapping #667 on a path neither of them shares: two DIFFERENT files judged
# as one. So an entry that another entry OF THE SAME LIST names a file under is
# dropped first — the file entry is the claim, the directory is only where it
# lives. A directory that appears ALONE is untouched and still contains
# everything under it: that one is an honest "I touch things under here".
dep_overlap() {
  awk 'NR==FNR{a[++na]=$0;next}
    {b[++nb]=$0}
    END{
      for(i=1;i<=na;i++) for(j=1;j<=na;j++) if(index(a[j],a[i]"/")==1){da[i]=1;break}
      for(i=1;i<=nb;i++) for(j=1;j<=nb;j++) if(index(b[j],b[i]"/")==1){db[i]=1;break}
      for(i=1;i<=nb;i++){
        if(db[i])continue
        for(j=1;j<=na;j++){
          if(da[j])continue
          p=a[j]; q=b[i]
          if(q==p || index(q,p"/")==1 || index(p,q"/")==1){print p" ~ "q; if(++n>=3)exit}
        }
      }
    }' "${1:-}" "${2:-}" 2>/dev/null | head -3
}

# dep_declared_hard <blocker> <issue-body-file> -> rc 0 when the AUTHOR said so
#
# THE ESCAPE HATCH, and it is checked before any evidence is gathered. Two
# spellings, both meaning "do not verify this, I mean it":
#   Blocked-by: #N (hard)
#   Needs: #N
# A plan author who knows the child cannot compile without #N writes one of
# those and the launcher never second-guesses it. Everything else is a claim.
#
# ONE LINE CAN CARRY SEVERAL BLOCKERS (BH-515). bin/run-decompose.sh has
# written `Blocked-by: #A (hard), #B (hard)` since BH-481, and each `#N` is
# judged by the suffix that follows IT, wherever on the line it sits — so
# `#A, #B (hard)` declares B hard and leaves A to be verified like any claim.
dep_declared_hard() {
  local n="${1:-}" f="${2:-}"
  [ -r "$f" ] || return 1
  grep -qiE "^[[:space:]>*_#-]*blocked[- ]by\b.*#${n}[[:space:]]*\((hard|blocking)\)" "$f" && return 0
  grep -qiE "^[[:space:]>*_#-]*needs\b[^#]*#$n([^0-9]|$)" "$f" && return 0
  return 1
}

# dep_depends_line <blocker> <plan.md> -> prints "hard <reason>" | "soft <reason>"
#   rc 1 when the plan declares nothing for this blocker.
#
# THE SEMANTIC HALF. prompts/plan-contract.md §7 makes this line mandatory for a
# ticket with Blocked-by lines: `DEPENDS: #N hard|soft — <reason>`. Both dash
# spellings are accepted (a model that types `-` instead of `—` has still said
# the thing), and the line is matched anywhere in the plan rather than under a
# required heading, because a verdict that depends on a heading's exact wording
# is a verdict that flips on formatting.
dep_depends_line() {
  local n="${1:-}" plan="${2:-}" ln kind why
  [ -s "$plan" ] || return 1
  ln=$(grep -iE "^[[:space:]>*_-]*(\*\*)?DEPENDS[[:space:]]*:[[:space:]]*#$n([^0-9]|$)" "$plan" | head -1)
  [ -n "$ln" ] || return 1
  kind=$(printf '%s' "$ln" | sed -nE "s/.*#${n}[^A-Za-z]*(hard|soft|HARD|SOFT)([^A-Za-z].*|$)/\1/p" | tr 'A-Z' 'a-z')
  [ -n "$kind" ] || return 1
  # Everything after the kind word, with one separator eaten. Anchored on the
  # kind rather than on "the last dash in the line", so a reason that itself
  # contains a dash survives intact.
  why=$(printf '%s' "$ln" | sed -E "s/.*#${n}[^A-Za-z]*(hard|soft|HARD|SOFT)[[:space:]]*(—|–|--|-|:)?[[:space:]]*//" \
        | sed -e 's/[[:space:]]*$//' -e 's/\*\*$//')
  [ -n "$why" ] || why="no reason given"
  printf '%s %s\n' "$kind" "$why"
}

# dep_sha <file...> -> one short content digest over the files that exist
#   ("-" for each that does not). The pieces of the evidence fingerprint.
dep_sha() {
  local f out=""
  for f in "$@"; do
    if [ -s "$f" ]; then out="$out$(sha256sum "$f" 2>/dev/null | cut -c1-16)|"
    else out="$out-|"; fi
  done
  printf '%s' "$out"
}
