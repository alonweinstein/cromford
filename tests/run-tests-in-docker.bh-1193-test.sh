#!/bin/bash
# tests/run-tests-in-docker.bh-1193-test.sh — the docker endpoint is resolved in
# ONE place, and a remote endpoint SHIPS the tree instead of bind-mounting it
# (BH-1193).
#
# THE BUG THIS PREVENTS. `docker run -v "$REPO:/repo:ro"` resolves the mount on
# the DAEMON's host, not on the client's. Point the runner at a remote daemon
# with DOCKER_HOST and that path does not exist there, so docker creates an
# empty /repo, the suite runner matches no suites and the run is useless — with
# no error from docker, which honoured the endpoint exactly as asked. So the
# remote path stages the tree with rsync and does create -> cp -> start instead.
#
# WHY THERE IS NO DOCKER HERE. A stub `docker` goes first on PATH and records
# every verb and its argv, the way tests/run-tests-in-docker-harness-test.sh
# section F already does. Nothing starts a container, which is what makes this
# file safe under the `tests/*.sh` sweep.
#
# Sections: A the resolver, B the production entry point on both paths, C the
# image build reaches the resolved daemon, D the one-place ratchet, E two
# concurrent runs share nothing, F CI cannot take the skip path.
#
# RSYNC_REQUIRED=1 TURNS THE SKIP INTO A FAILURE, and CI sets it. The remote
# sections need a real rsync to stage a real tree, and a laptop without one
# still skips them — but a CI runner that skips them is the shape BH-1128 was
# about: the Fly bh-ci image carried no rsync, so every assertion that proves
# this feature would have evaporated into one line and an exit 0. Section F
# pins the export in the workflow so it cannot be dropped later.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/docker-host.sh"
RUNNER="$DIR/bin/run-tests-in-docker.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$1" = "$2" ] && ok || bad "$3 (got '$1', want '$2')"; }
has()   { grep -qF -- "$2" "$1" && ok || bad "$3"; }
lacks() { grep -qF -- "$2" "$1" && bad "$3" || ok; }

[ -r "$LIB" ] || { bad "bin/lib/docker-host.sh is missing"; echo "run-tests-in-docker.bh-1193: $PASS passed, $FAIL failed"; exit 1; }

# ── A: the resolver ─────────────────────────────────────────────────────────
# Fixture env dirs. ETC_HARNESS_ENV is pinned at a path that does not exist so
# no case can fall through to a real /etc/harness/env on the box running this.
NOETC="$T/no-etc"
mkdir -p "$T/h-set/env" "$T/h-comment/env" "$T/h-noenvfile/env" "$T/h-noenvdir"
printf 'OTHER=x\nDOCKER_HOST=ssh://root@fixture-host\nSECRET=shhh\n' > "$T/h-set/env/global.env"
printf '#DOCKER_HOST=ssh://commented-host\n' > "$T/h-comment/env/global.env"

resolve() { # <harness-root> [DOCKER_HOST value, or the literal UNSET]
  local root="$1" dh="${2:-UNSET}"
  if [ "$dh" = UNSET ]; then
    env -u DOCKER_HOST HARNESS="$root" ETC_HARNESS_ENV="$NOETC" \
      bash -c ". \"$LIB\"; docker_host_resolve"
  else
    env DOCKER_HOST="$dh" HARNESS="$root" ETC_HARNESS_ENV="$NOETC" \
      bash -c ". \"$LIB\"; docker_host_resolve"
  fi
}

eq "$(resolve "$T/h-set" 'tcp://exported:2375')" 'tcp://exported:2375' \
   "A1: an exported DOCKER_HOST must beat the env file"
eq "$(resolve "$T/h-set")" 'ssh://root@fixture-host' \
   "A2: the env file's DOCKER_HOST must be returned when nothing is exported"
eq "$(resolve "$T/h-comment")" '' \
   "A3: a commented #DOCKER_HOST= line is not a setting"
eq "$(resolve "$T/h-noenvfile")" '' \
   "A4: an env dir with no global.env resolves to nothing"
eq "$(resolve "$T/h-noenvdir")" '' \
   "A5: a harness root with no env dir resolves to nothing"
eq "$(resolve "$T/h-set" '   ')" 'ssh://root@fixture-host' \
   "A6: a whitespace-only exported DOCKER_HOST is not a setting"
# Nothing but the endpoint leaves global.env: the file is sourced in a subshell.
eq "$(env -u DOCKER_HOST HARNESS="$T/h-set" ETC_HARNESS_ENV="$NOETC" \
        bash -c ". \"$LIB\"; docker_host_resolve >/dev/null; printf '%s' \"\${SECRET:-}\"")" '' \
   "A7: sourcing global.env must not leak its other variables into the caller"

classify() { # <endpoint> <want: remote|local>
  local got
  if env -u DOCKER_HOST bash -c ". \"$LIB\"; docker_host_is_remote \"\$1\"" _ "$1"; then
    got=remote
  else
    got=local
  fi
  eq "$got" "$2" "A: '$1' classified"
}
# The adversarial negatives: misclassifying a remote endpoint as local silently
# runs the suite against an empty /repo, which is the whole defect.
classify ''                                 local
classify '   '                              local
classify 'unix:///var/run/docker.sock'      local
classify 'unix:///Users/x/.colima/docker.sock' local
classify 'fd://'                            local
classify 'ssh://root@host'                  remote
classify 'ssh://user@host:2222'             remote
classify 'tcp://10.0.0.5:2375'              remote
# and no argument at all, which is what an unset endpoint reaches it as
eq "$(env -u DOCKER_HOST bash -c ". \"$LIB\"; docker_host_is_remote && echo remote || echo local")" \
   local "A: no endpoint at all classified"

eq "$(env -u DOCKER_HOST bash -c ". \"$LIB\"; docker_host_label ''")" 'the local docker daemon' \
   "A8: the label for no endpoint"
eq "$(env -u DOCKER_HOST bash -c ". \"$LIB\"; docker_host_label ssh://root@host")" 'ssh://root@host' \
   "A9: the label for a remote endpoint is the endpoint"

OUT_S=$(env -u DOCKER_HOST bash -c ". \"$LIB\"" 2>&1 </dev/null)
RC_S=$?
[ -z "$OUT_S" ] && ok || bad "A10: sourcing the lib printed: $OUT_S"
eq "$RC_S" 0 "A11: sourcing the lib must exit 0"

# ── the stub docker ─────────────────────────────────────────────────────────
mkdir -p "$T/stub"
cat > "$T/stub/docker" <<'STUB'
#!/bin/bash
# Records every verb and its argv under $STUB_REC. Return codes are knobs so a
# test can make the daemon unreachable, the image missing, or the run fail.
rec="$STUB_REC"
mkdir -p "$rec"
v="${1:-}"
printf '%s\n' "$v" >> "$rec/verbs"
case "$v" in
  info)   printf '%s\n' "${DOCKER_HOST:-}" > "$rec/info-env"
          exit "${STUB_INFO_RC:-0}" ;;
  image)  printf '%s\n' "${DOCKER_HOST:-}" > "$rec/image-env"
          exit "${STUB_IMAGE_RC:-0}" ;;
  build)  printf '%s\n' "$@" > "$rec/build-args"
          printf '%s\n' "${DOCKER_HOST:-}" > "$rec/build-env"
          cat > /dev/null
          exit "${STUB_BUILD_RC:-0}" ;;
  run)    printf '%s\n' "$@" > "$rec/run-args"
          printf '%s\n' "${DOCKER_HOST:-}" > "$rec/run-env"
          cat > "$rec/run-stdin"
          exit "${STUB_RUN_RC:-4}" ;;
  create) printf '%s\n' "$@" > "$rec/create-args"
          printf '%s\n' "${DOCKER_HOST:-}" > "$rec/create-env"
          printf 'cid-%s\n' "$$"
          exit "${STUB_CREATE_RC:-0}" ;;
  cp)     printf '%s\n' "$@" > "$rec/cp-args"
          if [ "${STUB_CP_COPY:-0}" = 1 ]; then cp -R "$2" "$rec/copied" 2>/dev/null; fi
          exit "${STUB_CP_RC:-0}" ;;
  start)  printf '%s\n' "$@" > "$rec/start-args"
          cat > "$rec/start-stdin"
          exit "${STUB_START_RC:-4}" ;;
  # `docker inspect --format '{{.State.Status}}'` — how the runner tells a
  # container that ran and failed suites from one that never started at all.
  inspect) printf '%s\n' "$@" >> "$rec/inspect-args"
          printf '%s\n' "${STUB_STATE:-exited}"
          exit 0 ;;
  rm)     printf '%s\n' "$@" >> "$rec/rm-args"
          exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/stub/docker"

# The stub's knobs are plain shell variables with defaults, passed explicitly by
# run_runner and RESET after every run: `VAR=x run_runner …` would leak into the
# next case, because bash keeps a prefix assignment made to a FUNCTION call.
# RUN_HARNESS is the harness root the runner resolves its env dir from: a
# fixture with no env dir by default, so no case can read the global.env of a
# real box that happens to be running this suite.
STUB_INFO_RC=0; STUB_IMAGE_RC=0; STUB_CP_COPY=0; STUB_START_RC=4; STUB_RUN_RC=4
STUB_STATE=exited
RUN_HARNESS="$T/h-noenvdir"
run_runner() { # <rec-dir> <endpoint, or UNSET> [runner args...]
  local rec="$1" dh="$2"; shift 2
  mkdir -p "$rec"
  # `env`'s options come before its assignments, or -u is read as the command.
  local -a pre=(env)
  if [ "$dh" = UNSET ]; then pre+=(-u DOCKER_HOST); fi
  pre+=("PATH=$T/stub:$PATH" "STUB_REC=$rec"
    "HARNESS=$RUN_HARNESS" "ETC_HARNESS_ENV=$NOETC"
    "STUB_INFO_RC=$STUB_INFO_RC" "STUB_IMAGE_RC=$STUB_IMAGE_RC"
    "STUB_CP_COPY=$STUB_CP_COPY" "STUB_START_RC=$STUB_START_RC"
    "STUB_RUN_RC=$STUB_RUN_RC" "STUB_STATE=$STUB_STATE")
  if [ "$dh" != UNSET ]; then pre+=("DOCKER_HOST=$dh"); fi
  "${pre[@]}" bash "$RUNNER" "$@" > "$rec/out.txt" 2> "$rec/err.txt" </dev/null
  echo $? > "$rec/rc"
  STUB_INFO_RC=0; STUB_IMAGE_RC=0; STUB_CP_COPY=0; STUB_START_RC=4; STUB_RUN_RC=4
  STUB_STATE=exited
  RUN_HARNESS="$T/h-noenvdir"
}
rc_of() { cat "$1/rc"; }
verb_has() { grep -qxF "$2" "$1/verbs"; }

REMOTE_EP='tcp://127.0.0.1:12345'

# ── B1: no DOCKER_HOST — the local path does not move ───────────────────────
B1="$T/b1"
run_runner "$B1" UNSET
eq "$(rc_of "$B1")" 4 "B1: the runner must exit with the container's status"
verb_has "$B1" run && ok || bad "B1: the local path must still use docker run"
has "$B1/run-args" "-v" "B1: the local run lost its bind mount flag"
has "$B1/run-args" "$DIR:/repo:ro" "B1: the local run must bind-mount the checkout read-only"
for v in create cp start; do
  verb_has "$B1" "$v" && bad "B1: the local path issued a '$v' verb" || ok
done

# ── B1b: a whitespace-only DOCKER_HOST is local ALL THE WAY DOWN ────────────
# The resolver calls '   ' not-configured and the run line says "the local
# docker daemon". If the variable is only skipped-over rather than unset, every
# docker call still carries the garbage: the real client then fails to parse it
# and the operator is sent to Docker Desktop by a message about the LOCAL
# daemon, for a fault that is in their env. The run line has to be true for
# docker too, not just for the reader.
B1W="$T/b1w"
run_runner "$B1W" '   '
eq "$(rc_of "$B1W")" 4 "B1b: a whitespace-only endpoint must take the local path"
has "$B1W/out.txt" "the local docker daemon" "B1b: the run line must say local"
verb_has "$B1W" run && ok || bad "B1b: a whitespace-only endpoint did not use docker run"
eq "$(cat "$B1W/info-env")" '' "B1b: docker info was handed the whitespace endpoint"
eq "$(cat "$B1W/run-env")" '' "B1b: docker run was handed the whitespace endpoint"
eq "$(cat "$B1/run-env")" '' "B1: docker run saw a DOCKER_HOST with nothing configured"

# ── B2..B6: the remote path ────────────────────────────────────────────────
# The remote path stages the tree with rsync, so without rsync there is nothing
# to drive. A dev laptop without it still skips; CI is not allowed to, because a
# skip here means the whole of what BH-1193 builds went untested and the run
# still said 0. RSYNC_REQUIRED=1 (exported by harness-ci.yml's tests step, next
# to CODEGRAPH_REQUIRED / AGE_REQUIRED / SEMGREP_REQUIRED) makes that a failure.
if ! command -v rsync >/dev/null 2>&1; then
  if [ "${RSYNC_REQUIRED:-0}" = 1 ]; then
    bad "RSYNC_REQUIRED=1 but rsync is not on PATH — sections B2-B6, C and E did not run, so nothing here tested the remote path"
  else
    echo "run-tests-in-docker.bh-1193: SKIPPED sections B2-B6, C and E — rsync is not on PATH (set RSYNC_REQUIRED=1 to fail instead)"
  fi
else

B2="$T/b2"
STUB_CP_COPY=1 run_runner "$B2" "$REMOTE_EP"
# order: create, then cp, then start. A container that was created and never
# started must never be able to report a green run.
ORDER=$(grep -E '^(create|cp|start)$' "$B2/verbs" | tr '\n' ' ')
eq "$ORDER" "create cp start " "B2: the remote path's verb order"
verb_has "$B2" run && bad "B2: the remote path must not use docker run" || ok
lacks "$B2/create-args" "-v" "B2: the remote create still carries a bind mount (-v resolves on the DAEMON's host)"
has "$B2/create-args" "SUITES=" "B2: SUITES did not reach the remote container"
has "$B2/create-args" "SUITE_SHARD=" "B2: SUITE_SHARD did not reach the remote container"
has "$B2/create-args" "HARNESS_TEST_SANDBOX=1" "B2: HARNESS_TEST_SANDBOX did not reach the remote container"
has "$B2/create-args" "suite_runner_main" "B2: the remote container does not call suite_runner_main"
has "$B2/out.txt" "$REMOTE_EP" "B2: the run line does not name the endpoint"
[ -d "$B2/copied/tests" ] && ok || bad "B2: the shipped tree has no tests/ in it"
[ -e "$B2/copied/.git" ] && bad "B2: the shipped tree carries .git" || ok
CP_DEST=$(sed -n '3p' "$B2/cp-args")
eq "${CP_DEST#*:}" "/repo" "B2: the tree must be copied to /repo in the container"

B3="$T/b3"
run_runner "$B3" "$REMOTE_EP" tests/x-test.sh
eq "$(rc_of "$B3")" 4 "B3: the remote run must exit with the container's status"
grep -qxF 'SUITES=tests/x-test.sh' "$B3/create-args" && ok \
  || bad "B3: a named suite is not forwarded to the remote container"

B4="$T/b4"
STUB_INFO_RC=1 run_runner "$B4" "$REMOTE_EP"
eq "$(rc_of "$B4")" 2 "B4: an unreachable configured endpoint must exit 2"
has "$B4/err.txt" "$REMOTE_EP" "B4: the failure message does not name the endpoint"
for v in run create start; do
  verb_has "$B4" "$v" && bad "B4: the runner fell back and issued '$v' on the local daemon" || ok
done

B5="$T/b5"
run_runner "$B5" "$REMOTE_EP"
lacks "$B5/start-args" "-i" "B5: docker start attached stdin (-i) — a suite can then eat the runner"
[ -f "$B5/start-stdin" ] && [ ! -s "$B5/start-stdin" ] && ok \
  || bad "B5: the container was handed a non-empty stdin"

B6="$T/b6"
STUB_START_RC=7 run_runner "$B6" "$REMOTE_EP"
eq "$(rc_of "$B6")" 7 "B6: the run's exit status is the container's"
[ -s "$B6/rm-args" ] && ok || bad "B6: a finished run left its container behind (no docker rm)"
B6_CID=$(grep -m1 '^cid-' "$B6/rm-args" || true)
[ -n "$B6_CID" ] && ok || bad "B6: the rm did not name the container id"
B6_STAGE=$(sed -n '2p' "$B6/cp-args")
B6_STAGE_DIR=$(dirname "$B6_STAGE")
[ -n "$B6_STAGE_DIR" ] && [ ! -e "$B6_STAGE_DIR" ] && ok \
  || bad "B6: the staging directory $B6_STAGE_DIR survived the run"

# ── B7: a container that never ran is exit 2, not "one suite failed" ───────
# `docker start` answers 1 for a docker-level failure, and 1 is also a real
# suite count. Both halves matter: the honest red must stay 1, and the run that
# never happened must be this file's 2. The local path never had the ambiguity —
# `docker run` answers 125 there, outside the plausible count.
B7="$T/b7"
STUB_START_RC=1 STUB_STATE=exited run_runner "$B7" "$REMOTE_EP"
eq "$(rc_of "$B7")" 1 "B7: one genuinely failing suite must still exit 1"

B7N="$T/b7n"
STUB_START_RC=1 STUB_STATE=created run_runner "$B7N" "$REMOTE_EP"
eq "$(rc_of "$B7N")" 2 "B7: a container that never left 'created' must exit 2, not report 1 failing suite"
has "$B7N/err.txt" "$REMOTE_EP" "B7: the never-ran message does not name the endpoint"
[ -s "$B7N/rm-args" ] && ok || bad "B7: the container that never ran was left behind"

# ── C: the image is built on the resolved daemon, with the same tag ─────────
CL="$T/c-local"; CR="$T/c-remote"
STUB_IMAGE_RC=1 run_runner "$CL" UNSET
STUB_IMAGE_RC=1 run_runner "$CR" "$REMOTE_EP"
tag_of() { awk '/^-t$/ { getline; print; exit }' "$1"; }
TAG_L=$(tag_of "$CL/build-args"); TAG_R=$(tag_of "$CR/build-args")
[ -n "$TAG_L" ] && ok || bad "C: the local build recorded no -t tag (the scan found nothing)"
eq "$TAG_R" "$TAG_L" "C: the remote build must use the same image tag as the local one"
# The build context is `-` (nothing), not the checkout. The inline Dockerfile
# has no COPY and no ADD, so a $REPO context was tarred and shipped over the ssh
# link for nothing — 47 MB before the build could start.
eq "$(tail -n 1 "$CR/build-args")" '-' "C: the build context must be '-' (no context), or every remote build uploads the checkout first"
lacks "$CR/build-args" "$DIR" "C: the build still sends the checkout as a context nobody reads"
eq "$(cat "$CR/image-env")" "$REMOTE_EP" "C: docker image inspect did not see the endpoint"
eq "$(cat "$CR/build-env")" "$REMOTE_EP" "C: docker build did not see the endpoint"
eq "$(cat "$CR/create-env")" "$REMOTE_EP" "C: docker create did not see the endpoint"

# C2: the whole chain, with NOTHING exported — <env dir>/global.env is where a
# Mac sets this once, and the value has to reach docker's own environment or the
# image is built on the machine the run was supposed to leave alone.
CF="$T/c-file"
RUN_HARNESS="$T/h-set"
STUB_IMAGE_RC=1 run_runner "$CF" UNSET
eq "$(cat "$CF/create-env")" 'ssh://root@fixture-host' \
   "C2: an endpoint configured only in global.env never reached docker"
eq "$(cat "$CF/build-env")" 'ssh://root@fixture-host' \
   "C2: the image was built on the wrong daemon"
verb_has "$CF" cp && ok || bad "C2: a file-configured endpoint did not take the ship-the-tree path"

# ── E: two concurrent runs share nothing ───────────────────────────────────
E1="$T/e1"; E2="$T/e2"
run_runner "$E1" "$REMOTE_EP" & P1=$!
run_runner "$E2" "$REMOTE_EP" & P2=$!
wait "$P1"; wait "$P2"
S1=$(dirname "$(sed -n '2p' "$E1/cp-args")")
S2=$(dirname "$(sed -n '2p' "$E2/cp-args")")
[ -n "$S1" ] && [ -n "$S2" ] && [ "$S1" != "$S2" ] && ok \
  || bad "E: two concurrent runs staged the tree in the same directory ($S1 / $S2)"
C1=$(grep -m1 '^cid-' "$E1/rm-args" || true)
C2=$(grep -m1 '^cid-' "$E2/rm-args" || true)
[ -n "$C1" ] && [ -n "$C2" ] && [ "$C1" != "$C2" ] && ok \
  || bad "E: two concurrent runs removed the same container id ($C1 / $C2)"

fi

# ── D: the one-place ratchet ───────────────────────────────────────────────
# Who READS the endpoint variable — an expansion, not the export that hands it
# to docker. Exactly one non-test file may, and a scan that finds nothing is a
# broken ratchet, not a green one.
READERS=$(cd "$DIR" && find bin tests \( -name .git -o -name node_modules -o -name .claude \) -prune -o \
  -type f -name '*.sh' -print 2>/dev/null | LC_ALL=C sort \
  | while IFS= read -r f; do grep -qE '\$\{?DOCKER_HOST' "$f" && printf '%s\n' "$f"; done)
NREAD=$(printf '%s\n' "$READERS" | grep -c . || true)
[ "$NREAD" -ge 1 ] && ok || bad "D: the scan found no file reading DOCKER_HOST — the ratchet is scanning for nothing"
EXTRA=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    bin/lib/docker-host.sh) continue ;;
    tests/*) continue ;;
  esac
  EXTRA="$EXTRA $f"
done <<EOF
$READERS
EOF
[ -z "$EXTRA" ] && ok || bad "D: these files read DOCKER_HOST themselves instead of calling docker_host_resolve:$EXTRA"

# ── F: CI cannot take the skip path ────────────────────────────────────────
# The gate above is only worth the export behind it. Where CI runs is a repo
# variable (BH-1206), so a job lands on the Fly bh-ci image or on a hosted one
# between one run and the next, and the Fly image is exactly the one that had no
# rsync. Both halves are pinned here: the workflow installs rsync the way it
# installs age and zstd, and it sets RSYNC_REQUIRED=1 so a run that still cannot
# find it is red rather than a skip line with an exit 0. This is the shape
# tests/codegraph-injection-test.sh already uses for CODEGRAPH_REQUIRED.
WF="$DIR/.github/workflows/harness-ci.yml"
[ -r "$WF" ] && ok || bad "F: .github/workflows/harness-ci.yml is missing"
grep -q 'RSYNC_REQUIRED=1' "$WF" \
  && ok || bad "F: CI must export RSYNC_REQUIRED=1, or a runner without rsync skips everything this ticket built and still exits 0"
grep -q 'ci-tool-present.sh rsync' "$WF" \
  && ok || bad "F: CI must guard-install rsync the way it guard-installs age and zstd"
# And the test image, which is the other place these sections have to run.
grep -qE '^[^#]*\brsync\b' "$DIR/fly/Dockerfile" \
  && ok || bad "F: fly/Dockerfile does not install rsync — the bh-ci runner is the image that made this a skip"

echo "run-tests-in-docker.bh-1193: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
