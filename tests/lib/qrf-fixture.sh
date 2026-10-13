# shellcheck shell=bash
# tests/lib/qrf-fixture.sh — BH-2338: the scratch harness and fake worker for
# bin/queue-rows-flip-preflight.sh and its per-gate modules (bin/lib/qrf/*.sh).
# Sourced by suites, never executed. Every function takes its roots as
# arguments or reads the QRF_FX it exported itself.
#
# The worker is a fake `curl` first on PATH, so the real _jobs_req runs
# unmodified (the tests/routing-flip-checklist.bh-1627-test.sh approach). Each
# request appends `METHOD /route` to $QRF_FX/req.log, then answers the last
# registration for that `METHOD /route` from $QRF_FX/routes, or 404 when there
# is none. ssh, rsync and gh are stubs that log `EXEC <tool>` and exit 1, so a
# call to any of them shows up in qrf_fixture_methods.
#
#   qrf_fixture_init <scratch-root> <repo-dir>
#       <root>/h is $HARNESS (a copy of <repo>/bin, env/global.env with
#       HARNESS_SECRET and JOBS_URL); <root>/tmp is $TMPDIR, outside $HARNESS.
#   qrf_fixture_route <METHOD> <route> <http> <body>
#   qrf_fixture_methods     distinct METHOD column of req.log
#   qrf_fixture_reqs        req.log as written

qrf_fixture_init() {
  local root="$1" repo="$2" s
  QRF_FX_PATH0="${QRF_FX_PATH0:-$PATH}"
  mkdir -p "$root/h/env" "$root/fx/bodies" "$root/tmp" "$root/fakebin" || return 1
  cp -a "$repo/bin" "$root/h/" || return 1
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$root/h/env/global.env"
  : > "$root/fx/routes"; : > "$root/fx/req.log"
  cat > "$root/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) shift 2;; *) shift;; esac; done
ROUTE="/${URL#*://*/}"
printf '%s %s\n' "$METHOD" "$ROUTE" >> "$QRF_FX/req.log"
HIT=$(awk -v m="$METHOD" -v r="$ROUTE" '$1 == m && $2 == r { h = $3; f = $4 } END { if (h != "") print h, f }' "$QRF_FX/routes")
if [ -n "$HIT" ]; then cat "${HIT#* }"; printf '\n%s' "${HIT%% *}"
else printf '{"error":"not found"}\n404'; fi
exit 0
CURL
  for s in ssh rsync gh; do
    printf '#!/bin/bash\nprintf "EXEC %s %%s\\n" "$*" >> "$QRF_FX/req.log"\nexit 1\n' "$s" > "$root/fakebin/$s"
  done
  chmod +x "$root/fakebin"/*
  unset HARNESS_SECRET JOBS_URL
  export HARNESS="$root/h" QRF_FX="$root/fx" TMPDIR="$root/tmp" JOBS_RETRIES=0 JOBS_TIMEOUT=5
  export PATH="$root/fakebin:$QRF_FX_PATH0"
}

qrf_fixture_route() { # qrf_fixture_route <METHOD> <route> <http> <body>
  local f; f=$(mktemp "$QRF_FX/bodies/b.XXXXXX") || return 1
  printf '%s' "$4" > "$f"
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$f" >> "$QRF_FX/routes"
}

qrf_fixture_methods() { [ -s "$QRF_FX/req.log" ] && awk '{ print $1 }' "$QRF_FX/req.log" | sort -u; return 0; }
qrf_fixture_reqs() { cat "$QRF_FX/req.log"; }
