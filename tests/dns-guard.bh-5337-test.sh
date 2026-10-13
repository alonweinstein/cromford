#!/bin/bash
# tests/dns-guard.bh-5337-test.sh — BH-5337 part 3: bin/dns-guard.sh replaces a
# dangling systemd-resolved stub symlink at /etc/resolv.conf with a static file
# (1.1.1.1, 8.8.8.8) when /run/systemd/resolve does not exist, and writes ONE
# `dns: dead` ALERTS line when `getent hosts api.github.com` fails. Every path
# is a seam (DNS_GUARD_RESOLV, DNS_GUARD_SYSTEMD_DIR, HARNESS); the alert goes
# through the real bin/alert-line.sh into $T/h/logs/ALERTS.log (no beat.sh in
# the scratch harness, so nothing leaves the box); getent and mv are stubs.
#   D1  dangling ../run/systemd/resolve/stub-resolv.conf, no systemd dir: a
#       regular file with exactly the two nameserver lines; `dns: replaced`.
#   D1b the same for an absolute /run/systemd/resolve/resolv.conf link.
#   D2  the same link with the systemd dir present: untouched.
#   D3  getent fails: exactly one ALERTS line with `dns: dead` and the host,
#       no `dns: ok`, rc 0. getent answers: `dns: ok`, no ALERTS line.
#   D4  a regular file (written by hand): byte-identical after the run.
#   D5  the replace fails (mv refuses): rc 0, the link stays, no `replaced`,
#       and the canary's `dns: dead` line names the dangling link.
#   D6  a link to /run/resolvconf/resolv.conf: untouched. D6b no file: none made.
#   D7  bin/update-runners.sh's guard line, run as written, runs the guard
#       before the harness sync (which needs DNS).
#   D8  bin/bootstrap-machine.sh's guard line, run as written, runs the guard
#       before the packages step.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/dns-guard.bh-5337-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
GUARD="$SRC/bin/dns-guard.sh"
[ -x "$GUARD" ] || { echo "FAIL: bin/dns-guard.sh does not exist or is not executable"; exit 1; }

mkdir -p "$T/fakebin" "$T/nomv" "$T/h/logs"
scratch_install_closure bin/alert-line.sh "$T/h" >/dev/null || { echo "FAIL: closure install of bin/alert-line.sh"; exit 1; }
[ ! -e "$T/h/bin/beat.sh" ] || { echo "FAIL: the closure brought bin/beat.sh: a test alert would leave the box"; exit 1; }
cat > "$T/fakebin/getent" <<EOF
#!/bin/bash
echo "\$*" >> "$T/getent.calls"
exit "\$(cat "$T/getent.rc" 2>/dev/null || echo 0)"
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/nomv/mv"
chmod +x "$T/fakebin/getent" "$T/nomv/mv"

E="$T/etc"; SD="$T/run/systemd/resolve"; R="$E/resolv.conf"; A="$T/h/logs/ALERTS.log"
reset() {
  scratch_rm "$T/etc"; scratch_rm "$T/run"; mkdir -p "$E"
  rm -f "$A" "$T/getent.calls"; echo 0 > "$T/getent.rc"
}
guard() { # guard [VAR=val ...] — OUT, RC
  OUT=$(env PATH="$T/fakebin:$PATH" DNS_GUARD_RESOLV="$R" DNS_GUARD_SYSTEMD_DIR="$SD" \
    HARNESS="$T/h" "$@" "$GUARD" 2>&1); RC=$?
}
alerts() { local n; n=$(grep -c . "$A" 2>/dev/null); echo "${n:-0}"; }

# ── D1: the dangling stub link is replaced ──
reset; ln -s ../run/systemd/resolve/stub-resolv.conf "$R"
guard
[ "$RC" = 0 ] && ok || bad "D1 rc=$RC"
[ -f "$R" ] && [ ! -L "$R" ] && ok || bad "D1 still a symlink: $(ls -l "$R" 2>&1)"
[ "$(grep -v '^#' "$R" 2>/dev/null)" = "$(printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8')" ] && ok \
  || bad "D1 want exactly the two nameserver lines, got: $(cat "$R" 2>&1)"
grep -q '^dns: replaced dangling stub symlink with static nameservers' <<<"$OUT" && ok || bad "D1 no replaced line: $OUT"
grep -q '^dns: ok' <<<"$OUT" && ok || bad "D1 no ok line: $OUT"
[ "$(alerts)" = 0 ] && ok || bad "D1 an ALERTS line with DNS working: $(cat "$A")"
# idempotent: a second run leaves the static file as it is
cp "$R" "$T/static.1"; guard
cmp -s "$R" "$T/static.1" && ! grep -q replaced <<<"$OUT" && ok || bad "D1 a second run rewrote the static file: $OUT"

# ── D1b: an absolute link into /run/systemd/resolve ──
reset; ln -s "$SD/resolv.conf" "$R"
guard
[ -f "$R" ] && [ ! -L "$R" ] && grep -qx 'nameserver 8.8.8.8' "$R" && ok || bad "D1b not replaced: $(ls -l "$R" 2>&1) $OUT"

# ── D2: systemd-resolved is there: leave it ──
reset; mkdir -p "$SD"; ln -s ../run/systemd/resolve/stub-resolv.conf "$R"
guard
[ -L "$R" ] && [ "$(readlink "$R")" = ../run/systemd/resolve/stub-resolv.conf ] && ok || bad "D2 a live systemd link was touched: $(ls -l "$R" 2>&1)"
grep -q replaced <<<"$OUT" && bad "D2 said replaced: $OUT" || ok

# ── D3: the canary ──
reset; printf 'nameserver 192.0.2.53\n' > "$R"; echo 2 > "$T/getent.rc"
guard
[ "$RC" = 0 ] && ok || bad "D3 rc=$RC (the guard always exits 0)"
[ "$(alerts)" = 1 ] && ok || bad "D3 want one ALERTS line, got $(alerts): $(cat "$A" 2>/dev/null)"
grep -q 'dns: dead' "$A" && grep -q 'api.github.com' "$A" && ok || bad "D3 ALERTS line: $(cat "$A" 2>/dev/null)"
grep -q '^dns: ok' <<<"$OUT" && bad "D3 said ok with getent failing: $OUT" || ok
[ "$(cat "$T/getent.calls")" = "hosts api.github.com" ] && ok || bad "D3 getent called as: $(cat "$T/getent.calls")"
rm -f "$A"; echo 0 > "$T/getent.rc"; guard
[ "$(alerts)" = 0 ] && grep -q '^dns: ok' <<<"$OUT" && ok || bad "D3 working DNS: alerts=$(alerts) out=$OUT"

# ── D4: a hand-written file is never rewritten ──
reset; printf 'nameserver 192.0.2.53\nsearch example.test\n' > "$R"; cp "$R" "$T/hand"
guard
cmp -s "$R" "$T/hand" && ok || bad "D4 a regular resolv.conf was changed: $(cat "$R")"

# ── D5: the replace fails ──
reset; ln -s ../run/systemd/resolve/stub-resolv.conf "$R"; echo 2 > "$T/getent.rc"
guard PATH="$T/nomv:$T/fakebin:$PATH"
[ "$RC" = 0 ] && ok || bad "D5 rc=$RC"
[ -L "$R" ] && ok || bad "D5 the link is gone after a failed mv: $(ls -l "$R" 2>&1)"
grep -q replaced <<<"$OUT" && bad "D5 said replaced after a failed mv: $OUT" || ok
grep -q 'dns: dead' "$A" 2>/dev/null && grep -q 'dangling symlink' "$A" && ok || bad "D5 ALERTS line: $(cat "$A" 2>/dev/null)"
[ -z "$(find "$E" -name '.resolv.conf.*' 2>/dev/null)" ] && ok || bad "D5 a temp file was left: $(ls -a "$E")"

# ── D6: another resolver's link, or no file at all ──
reset; ln -s /run/resolvconf/resolv.conf "$R"
guard
[ -L "$R" ] && [ "$(readlink "$R")" = /run/resolvconf/resolv.conf ] && ok || bad "D6 a resolvconf link was touched: $(ls -l "$R" 2>&1)"
reset
guard
[ ! -e "$R" ] && [ ! -L "$R" ] && ok || bad "D6b a missing resolv.conf was created"

# ── D7: update-runners runs the guard before the sync ──
reset; ln -s ../run/systemd/resolve/stub-resolv.conf "$R"
UR="$SRC/bin/update-runners.sh"
gl=$(grep -n 'dns-guard\.sh' "$UR" | grep -v '^[0-9]*:[[:space:]]*#')
sl=$(grep -n 'harness-sync\.sh' "$UR" | grep -v '^[0-9]*:[[:space:]]*#' | head -1)
[ "$(printf '%s\n' "$gl" | grep -c .)" = 1 ] && ok || bad "D7 want one dns-guard call in update-runners.sh, got: $gl"
[ -n "$gl" ] && [ -n "$sl" ] && [ "${gl%%:*}" -lt "${sl%%:*}" ] && ok || bad "D7 the guard (line ${gl%%:*}) is not before the sync (line ${sl%%:*})"
scratch_install_closure bin/dns-guard.sh "$T/h" >/dev/null || bad "D7 closure install of bin/dns-guard.sh"
printf '%s\n' "${gl#*:}" > "$T/ur-line.sh"
env PATH="$T/fakebin:$PATH" H="$T/h" LOG="$T/ur.log" \
  DNS_GUARD_RESOLV="$R" DNS_GUARD_SYSTEMD_DIR="$SD" bash "$T/ur-line.sh"; RC=$?
[ "$RC" = 0 ] && ok || bad "D7 the update-runners guard line rc=$RC"
[ -f "$R" ] && [ ! -L "$R" ] && grep -q 'dns: replaced' "$T/ur.log" 2>/dev/null && ok \
  || bad "D7 the update-runners line did not run the guard into its log: $(cat "$T/ur.log" 2>&1)"

# ── D8: bootstrap runs the guard before the packages step ──
reset; ln -s ../run/systemd/resolve/stub-resolv.conf "$R"
BM="$SRC/bin/bootstrap-machine.sh"
gl=$(grep -n 'dns-guard\.sh' "$BM" | grep -v '^[0-9]*:[[:space:]]*#')
pl=$(grep -n '== packages ==' "$BM" | head -1)
[ "$(printf '%s\n' "$gl" | grep -c .)" = 1 ] && ok || bad "D8 want one dns-guard call in bootstrap-machine.sh, got: $gl"
[ -n "$gl" ] && [ -n "$pl" ] && [ "${gl%%:*}" -lt "${pl%%:*}" ] && ok || bad "D8 the guard (line ${gl%%:*}) is not before packages (line ${pl%%:*})"
printf '%s\n' "${gl#*:}" > "$T/bm-line.sh"
OUT=$(env PATH="$T/fakebin:$PATH" HERE="$T/h/bin" HARNESS="$T/h" \
  DNS_GUARD_RESOLV="$R" DNS_GUARD_SYSTEMD_DIR="$SD" bash "$T/bm-line.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -f "$R" ] && [ ! -L "$R" ] && grep -q 'dns: replaced' <<<"$OUT" && ok \
  || bad "D8 the bootstrap line did not run the guard: rc=$RC $OUT"

echo "dns-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
