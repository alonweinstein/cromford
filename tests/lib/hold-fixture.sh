# tests/lib/hold-fixture.sh — the ticket read every PR-branch push now makes
# (BH-2504, bin/lib/hold-push.sh), answered for suites that drive a pushing lane
# and are about something else. Sourced, never executed; not a suite.
#
# A lane that pushes a PR branch reads the ticket's HOLD first, and an
# unanswered read is UNREADABLE, which pushes nothing — so a suite whose gh stub
# never heard of issue reads would see every push refused. These helpers answer
# that read the way a ticket nobody held answers it, and nothing more: a suite
# that is ABOUT holds writes its own issue and thread.
# shellcheck shell=bash

# hold_fixture_gh <dir> — write <dir>/gh: a FIXTURE `gh` that answers the plain
# REST issue read (an open, ai-build-labelled, unheld ticket), the thread read
# (empty) and nothing else. Put <dir> on PATH ahead of anything else.
hold_fixture_gh() {
  mkdir -p "$1" || return 1
  cat > "$1/gh" <<'EOF'
#!/bin/bash
# FIXTURE gh (tests/lib/hold-fixture.sh): an unheld ticket for the hold read.
. "$(dirname "$0")/hold-answer.sh"
hold_answer "$@" && exit 0
echo ''
exit 0
EOF
  hold_fixture_answer_lib "$1"
  chmod +x "$1/gh"
}

# hold_fixture_answer_lib <dir> — write <dir>/hold-answer.sh, whose hold_answer
# prints the unheld-ticket answer for an issue or thread READ (never a write) (under `-i` with
# the status line gh_rest judges, plain otherwise) and returns 0, or returns 1
# for anything else. A suite with its own gh stub sources it and asks first.
hold_fixture_answer_lib() {
  mkdir -p "$1" || return 1
  cat > "$1/hold-answer.sh" <<'EOF'
# FIXTURE (tests/lib/hold-fixture.sh): an unheld ticket for the BH-2504 hold read.
hold_answer() {
  local all="$*" body
  case " $all " in *" -X POST "*|*" -X PATCH "*|*" -X DELETE "*|*" -X PUT "*|*" --method "*|*" -f "*|*" -F "*) return 1 ;; esac
  case "$all" in
    *"/issues/"*"/comments"*) body='[]' ;;
    *"/issues/"*) body='{"number":1,"state":"open","title":"FIXTURE ticket","body":"","labels":[{"name":"ai-build"}]}' ;;
    *) return 1 ;;
  esac
  case " $all " in
    *" -i "*) printf 'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "$body" ;;
    *) printf '%s\n' "$body" ;;
  esac
  return 0
}
EOF
}

# hold_fixture_libs <repo-dir> <scratch-harness-root> — the push lib and the hold
# reader, where a copied lane looks for them ($H/bin/lib).
hold_fixture_libs() {
  mkdir -p "$2/bin/lib" || return 1
  cp "$1/bin/lib/hold-push.sh" "$1/bin/lib/hold.sh" "$2/bin/lib/"
}
