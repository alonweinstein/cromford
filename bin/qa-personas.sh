#!/bin/bash
# bin/qa-personas.sh — turn an ANSWERED persona questionnaire into the three
# files a project repo needs, and open a PR there. The operator half of #528.
#
# WHO ANSWERS. A persona is "sign in as this kind of user and click these
# things", and the lanes that read it will click them against real
# environments. The answers come from a person or from an agent reading the
# code (role guards, route tree, nav per role; skills/qa-personas carries the
# questions). The safety floor is mechanical, not a reader: the validator
# refuses a persona with no out_of_bounds entry and a write flow with no
# cleanup, and production never runs a production_safe:false flow. The PR still
# opens and the orchestrator reads the rendered map before it merges. This
# script itself calls no model.
#
# WHAT IT WRITES, into the PROJECT repo:
#   qa/personas.json                      the answers minus the app map
#   qa/apps.json                          {version: 1, apps: <the app map>}
#   docs/verification-map/personas.md     the same content, for a person
#
# The schema has ONE owner — bin/lib/qa-personas.sh, written down in
# docs/E2E-POLICY.md § Personas. This script sources it and calls
# qa_personas_validate; it carries no rule of its own, so a document this
# refuses is exactly a document the lanes would refuse.
#
# usage: qa-personas.sh <project> --from <answers.json> [--repo <dir>] [--dry-run]
#        qa-personas.sh <project> --interactive
#
#   --from <answers.json>  the answered questionnaire: the personas document
#                          plus a top-level `apps` map. One shape, no
#                          translation layer.
#   --repo <dir>           the project checkout (default ${REPOS_ROOT:-/root/repos}/<project>)
#   --dry-run              print the three rendered files and stop. No write,
#                          no git command, no gh call.
#   --interactive          print the questionnaire and the answers-file shape,
#                          then exit 2. This box is headless; there is no stdin
#                          loop to run.
#
# Exit codes: 0 = a PR was opened (its URL is the only thing on stdout, and it
# is printed only after gh hands one back), 1 = a refusal with one line on
# stderr, 2 = usage. Every refusal before the branch is cut writes nothing at
# all; the two that can happen after the commit (push failed, gh failed) leave
# the local branch and its commit behind and their stderr line says so.
#
# IRON GUARDRAIL 1: this script never pushes to main and never merges anything.
set -uo pipefail

SELF=$(basename "$0")
BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/qa-personas.sh
. "$BIN/lib/qa-personas.sh" || {
  printf '%s: cannot source %s/lib/qa-personas.sh\n' "$SELF" "$BIN" >&2; exit 1; }

die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit 1; }

usage() {
  {
    printf 'usage: %s <project> --from <answers.json> [--repo <dir>] [--dry-run]\n' "$SELF"
    printf '       %s <project> --interactive\n' "$SELF"
    printf 'the answers file is the personas document plus a top-level apps map;\n'
    printf 'run "%s <project> --interactive" for the questionnaire.\n' "$SELF"
  } >&2
}

questionnaire() {
  cat <<'EOF'
QA personas — the questionnaire. Answer these with the people who know the
product, then save the answers as one JSON file and run:

  qa-personas.sh <project> --from <answers.json>

1. Who are the personas? One per kind of user who can sign in. Give each a
   short id (lowercase letters, digits and dashes) and the role name its QA
   account uses.
2. How does each one sign in? v1 has one answer: clerk-ticket.
3. Which apps does each one own? The names from the apps map below, so a diff
   that only touches one app drives only the personas that own it.
4. What are the top 3-5 flows for each persona? Per flow: an id, a title, the
   route it starts at, the observable that proves it worked, and the clicks in
   between.
5. Which of those flows WRITE something? A write flow is production_safe:
   false, runs against preview only, and must say how to clean up after itself.
6. What must never be driven? The routes and actions that are out of bounds for
   that persona. At least one is required.

An agent may answer these from the code; see skills/qa-personas/SKILL.md.

The answers file is the personas document plus a top-level `apps` map:

{
  "version": 1,
  "apps": { "admin": ["apps/admin/**"], "web": ["apps/web/**", "src/**"] },
  "personas": [
    { "id": "owner", "role": "qa-owner", "sign_in": "clerk-ticket",
      "apps": ["web"], "out_of_bounds": ["/billing"],
      "flows": [
        { "id": "dashboard", "title": "See the dashboard", "route": "/dashboard",
          "observable": "the scans table renders", "production_safe": true,
          "steps": [ {"goto": "/dashboard"},
                     {"expect": {"selector": "role=table"}} ] },
        { "id": "new-scan", "title": "Start a scan", "route": "/scans/new",
          "observable": "a queued scan row appears", "production_safe": false,
          "cleanup": "delete the queued scan named qa-smoke",
          "steps": [ {"goto": "/scans/new"},
                     {"fill": {"selector": "input[name=name]", "value": "qa-smoke"}},
                     {"click": "button:has-text(\"Start scan\")"},
                     {"expect": {"selector": "role=row", "text": "qa-smoke"}} ] } ] } ]
}

Every rule of that shape lives in docs/E2E-POLICY.md § Personas. The generator
validates against it and refuses the whole file on the first defect.
EOF
}

# ── arguments ───────────────────────────────────────────────────────────────
PROJECT=""; ANSWERS=""; REPO_OPT=""; DRY=0; MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || { usage; exit 2; }
      ANSWERS="$2"; MODE=from; shift 2 ;;
    --repo)
      [ $# -ge 2 ] || { usage; exit 2; }
      REPO_OPT="$2"; shift 2 ;;
    --dry-run)     DRY=1; shift ;;
    --interactive) MODE=interactive; shift ;;
    -h|--help)     usage; exit 2 ;;
    -*)
      printf '%s: unknown flag %s\n' "$SELF" "$1" >&2; usage; exit 2 ;;
    *)
      [ -z "$PROJECT" ] || { printf '%s: unexpected argument %s\n' "$SELF" "$1" >&2; usage; exit 2; }
      PROJECT="$1"; shift ;;
  esac
done

if [ "$MODE" = interactive ]; then
  questionnaire
  exit 2
fi
[ -n "$PROJECT" ] || { usage; exit 2; }
[ -n "$MODE" ] || { usage; exit 2; }

REPO="${REPO_OPT:-${REPOS_ROOT:-/root/repos}/$PROJECT}"

# ── refusals, before anything is rendered ───────────────────────────────────
[ -f "$ANSWERS" ] && [ -r "$ANSWERS" ] || die "no such answers file: $ANSWERS"

# A dry run answers a question about the ANSWERS, not about the repo, so it
# touches neither: no git command runs on this path at all.
if [ "$DRY" = 0 ]; then
  [ -d "$REPO" ] || die "no such checkout: $REPO (pass --repo, or set REPOS_ROOT)"
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git work tree: $REPO"
  # captured first: head on a git pipe is a SIGPIPE race under pipefail (BH-1248).
  # The guard matters: `head -3 <<<""` emits one newline, which tr turns into a
  # space, and a DIRTY of " " would fail the -z test on a clean checkout.
  DIRTY=$(git -C "$REPO" status --porcelain 2>/dev/null)
  [ -z "$DIRTY" ] || DIRTY=$(head -3 <<<"$DIRTY" | tr '\n' ' ')
  [ -z "$DIRTY" ] || die "uncommitted work in $REPO: ${DIRTY% } — commit or stash it first"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qa-personas.XXXXXX") || die "cannot create a temp directory"
trap 'rm -rf "$TMP"' EXIT

# The split. An answers file jq cannot read is copied through verbatim so the
# refusal comes from the contract ("personas.json: .: not valid JSON") rather
# than from a raw jq error here.
if jq 'del(.apps)' "$ANSWERS" > "$TMP/personas.json" 2>/dev/null; then
  jq '{version: 1, apps: .apps}' "$ANSWERS" > "$TMP/apps.json" 2>/dev/null \
    || : > "$TMP/apps.json"
else
  cat "$ANSWERS" > "$TMP/personas.json" 2>/dev/null || : > "$TMP/personas.json"
  : > "$TMP/apps.json"
fi

qa_personas_validate "$TMP/personas.json" "$TMP/apps.json" || exit 1

# ── render the map entry ────────────────────────────────────────────────────
RENDER='
($apps[0].apps // {}) as $A
| def cell(f): (f) as $v | if ($v|type) == "string" and $v != "" then $v else "—" end;
  def appcell: . as $n
    | "`\($n)`" + (($A[$n] // []) | if length == 0 then ""
        else " (" + (map("`\(.)`") | join(", ")) + ")" end);
  def persona:
    ["## \(.role) (`\(.id)`)", "",
     "**How a user reaches it:** sign in as the `\(.role)` QA account (`sign_in: \(.sign_in)`), then open the route of the flow you are checking.", "",
     "**Apps it owns:** " + (if ((.apps // []) | length) == 0
        then "every path — this persona names no apps, so every diff is in scope for it"
        else ([.apps[] | appcell] | join(", ")) end), "",
     "| flow | route | observable | production safe | seed | cleanup |",
     "|---|---|---|---|---|---|"]
    + [.flows[] | "| \(.id) | `\(.route)` | \(.observable) | \(if .production_safe then "yes" else "no" end) | \(cell(.seed)) | \(cell(.cleanup)) |"]
    + ["", "**Manual-only / not automatable (out of bounds):**", ""]
    + (if ((.out_of_bounds // []) | length) == 0
       then ["- nothing recorded for this persona"]
       else [.out_of_bounds[] | "- `\(.)`"] end)
    + [""];
  ["# QA personas", "",
   "**What it is:** the QA personas for \($project) — who signs in, what each of them clicks through, and what nothing may drive. `qa/personas.json` and `qa/apps.json` are the machine-readable half that the QA lanes read; this page is the same content for a person.", "",
   "**How a user reaches it:** sign in as one of the personas below, using the QA account for its role, then follow the route in its flows table.", "",
   "**Preconditions / seed needs:** a QA account per role the sign-in method can mint a ticket for, plus whatever the seed column of a flow names. A flow whose `production safe` column says no writes data: it runs against preview only, and its cleanup column says how to undo it.", "",
   "**Do not hand-edit this page.** It is generated from `qa/personas.json` and `qa/apps.json` by `bin/qa-personas.sh`. Edit those, re-run the generator, and the two halves stay in step.", ""]
  + [.personas[] | persona]
  | flatten | .[]'

jq -r --arg project "$PROJECT" --slurpfile apps "$TMP/apps.json" \
  "$RENDER" "$TMP/personas.json" > "$TMP/personas.md" \
  || die "could not render docs/verification-map/personas.md from the answers"

P_JSON=qa/personas.json
P_APPS=qa/apps.json
P_MAP=docs/verification-map/personas.md

if [ "$DRY" = 1 ]; then
  for PAIR in "$P_JSON:personas.json" "$P_APPS:apps.json" "$P_MAP:personas.md"; do
    printf -- '--- %s\n' "${PAIR%%:*}"
    cat "$TMP/${PAIR##*:}"
    printf '\n'
  done
  exit 0
fi

# ── branch, commit, push, PR — in that order, and never main ────────────────
# One clock read for the whole run. The date-only branch name is also the
# dedupe key: a second run the same day finds the branch and refuses, which is
# the reversible answer.
BRANCH="qa/personas-$(date -u +%Y%m%d)"

# The branch is cut from main EXPLICITLY, never from whatever HEAD this checkout
# happens to be parked on. A checkout left on someone else's ticket branch — or
# on yesterday's qa/personas-<date> — would otherwise put that branch's commits
# into a PR opened against main, on a client's repo.
HEAD_BEFORE=$(git -C "$REPO" symbolic-ref -q --short HEAD 2>/dev/null) \
  || HEAD_BEFORE=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
[ -n "$HEAD_BEFORE" ] || die "cannot read the current HEAD of $REPO"
git -C "$REPO" rev-parse --verify -q refs/heads/main >/dev/null 2>&1 \
  || die "no local main branch in $REPO — the PR targets main, so the branch has to be cut from it"
# Same defect one step further out: a local main carrying commits origin does not
# have puts them in the PR too. Checked only when the checkout knows
# origin/main, and with no fetch — this lane does not touch the network before
# it has something to push.
if git -C "$REPO" rev-parse --verify -q refs/remotes/origin/main >/dev/null 2>&1 \
   && ! git -C "$REPO" merge-base --is-ancestor refs/heads/main refs/remotes/origin/main 2>/dev/null; then
  die "main in $REPO carries commits origin/main does not have — the PR would carry them as well, so sync main first"
fi
git -C "$REPO" checkout -qb "$BRANCH" main 2>/dev/null \
  || die "branch $BRANCH already exists in $REPO — open the PR it belongs to, or delete it and re-run"

mkdir -p "$REPO/qa" "$REPO/docs/verification-map" || die "cannot create qa/ and docs/verification-map/ in $REPO"
cp "$TMP/personas.json" "$REPO/$P_JSON" || die "cannot write $P_JSON in $REPO"
cp "$TMP/apps.json"     "$REPO/$P_APPS" || die "cannot write $P_APPS in $REPO"
cp "$TMP/personas.md"   "$REPO/$P_MAP"  || die "cannot write $P_MAP in $REPO"

{
  printf 'qa: the QA personas for %s\n\n' "$PROJECT"
  cat <<'EOF'
I generated qa/personas.json, qa/apps.json and the verification-map entry from
the answers file, drafted from the code or answered by a person. Nothing has
been driven against this app yet.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
} > "$TMP/commit-msg.txt"

git -C "$REPO" add "$P_JSON" "$P_APPS" "$P_MAP" >/dev/null 2>&1 \
  || die "cannot stage the three files in $REPO"
git -C "$REPO" -c user.name=qa-personas -c user.email=harness@box \
  commit -q -F "$TMP/commit-msg.txt" >/dev/null 2>&1 \
  || die "cannot commit $BRANCH in $REPO"

# The work is committed, so the checkout is safe to hand back: it belongs to the
# operator (or to the next lane), not to this run. Without this, a successful run
# leaves HEAD on qa/personas-<date> and tomorrow's run branches from it — the
# same stacked-PR failure the explicit `main` above prevents. Runs on every exit
# from here on, so a failed push or a failed gh also hands the checkout back;
# the branch itself stays, which is what the two error lines below promise.
trap 'git -C "$REPO" checkout -q "$HEAD_BEFORE" -- >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# The push and the PR both spend a GitHub credential, so resolve it ONCE here,
# the way bin/run-build.sh does: a repo-scoped App installation token that dies
# in an hour rather than the fleet-wide PAT that never does. Unarmed is today
# with no extra fork — gh_auth_for returns 1 without running a process when
# env/github-app.env is absent, GH_APP_TOKENS=0 or flags/gh-app-tokens-off
# exists, and GH_TOKEN keeps whatever the environment already gave it.
# shellcheck source=lib/gh-app-auth.sh
[ -r "$BIN/lib/gh-app-auth.sh" ] && . "$BIN/lib/gh-app-auth.sh"
GH_SLUG=$(git -C "$REPO" remote get-url origin 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
if command -v gh_auth_for >/dev/null 2>&1; then
  gh_auth_for "$GH_SLUG" || true
fi

# A PR for a branch that is not pushed is the half-state, so the push is the
# gate on gh, not a step beside it.
git -C "$REPO" push -q -u origin "$BRANCH" >/dev/null 2>&1 \
  || die "could not push $BRANCH to origin from $REPO — no PR was opened, and $BRANCH plus its commit stay in the checkout: delete the branch before re-running"

{
  printf '## What this is\n\n'
  printf 'The QA personas for %s: who signs in, the flows each of them drives, and\n' "$PROJECT"
  cat <<'EOF'
what nothing may drive. Three files, generated from the answers file (drafted
from the code by an agent, or answered by a person):

- `qa/personas.json` and `qa/apps.json` — what the QA lanes read.
- `docs/verification-map/personas.md` — the same content, for a person.

No flow has been driven yet. The schema is validated by
`bin/lib/qa-personas.sh` in cromford, which is the one reader of both
files.

## Before it merges

The orchestrator reads `docs/verification-map/personas.md` before the merge.
Every flow here becomes something an automated lane clicks through, so a wrong
route, or a write flow marked safe, is a real action against a real
environment. The floor is mechanical: every persona lists what it must never
touch (the validator refuses one with an empty out-of-bounds list), every flow
that writes is `production_safe: false` with a cleanup, and production never
runs a write flow.

To change anything, edit the answers and re-run the generator rather than
hand-editing the files — the machine-readable half and the page have to agree.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
} > "$TMP/pr-body.md"

# >>> pr trailers (BH-3987)
[ -r "$BIN/lib/pr-trailers.sh" ] && . "$BIN/lib/pr-trailers.sh"
if command -v pr_trailers_apply >/dev/null 2>&1; then
  pr_trailers_apply "$TMP/pr-body.md" lane:qa-personas none \
    || printf '%s: pr trailers: could not write %s — PR opened without trailers\n' "$SELF" "$TMP/pr-body.md" >&2
fi
URL=$(cd "$REPO" && gh pr create --base main --head "$BRANCH" \
  --title "qa: the QA personas for $PROJECT" --body-file "$TMP/pr-body.md" 2>/dev/null)
PR_RC=$?
# <<< pr trailers
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
[ "$PR_RC" = 0 ] && [ -n "$URL" ] \
  || die "$BRANCH is pushed but gh pr create failed — open the PR by hand from $BRANCH, or delete that branch here and on origin before re-running"

printf '%s\n' "$URL"
