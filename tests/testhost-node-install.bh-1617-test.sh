#!/bin/bash
# tests/testhost-node-install.bh-1617-test.sh — the test-host image installs the
# node CI runs, from the bake.node.version row, and refuses to build otherwise
# (BH-1617).
#
# WHY. fly/testhost/Dockerfile installed Debian trixie's apt nodejs, a node 20.
# On it tests/jobs-worker-test.sh failed 18 checks (no `node:sqlite`) and
# tests/repro-gate-test.sh 2 (no `--experimental-strip-types`), on unchanged
# main, on every test host. CI runs node 22.
#
# WHAT THIS PINS. The REAL fly/testhost/node-install.sh against a scratch prefix,
# a real tar.xz fixture whose bin/node is a stub, and a fakebin curl that serves
# the fixture from $T and logs every request:
#   A1 an empty version is refused before any download, naming NODE_VERSION;
#   A2 `latest`, `22`, `22.23` are refused with no download; `v<x.y.z>` is taken;
#   A3 a digest that does not match SHASUMS256.txt extracts nothing;
#   A3b SHASUMS256.txt with no line for the asset is refused;
#   A4 an installed node that reports another version is refused, both named;
#   A5 a node without node:sqlite is refused; A5b one that rejects
#      --experimental-strip-types is refused;
#   A6 the happy path installs and prints `testhost node: <v>`.
# And the Dockerfile and its deploy doc:
#   B  ARG NODE_VERSION has no default; the guard names it and fails when it is
#      empty (the guard line is extracted and RUN); apt installs no nodejs/npm;
#      node is installed before `npm install -g`; no x.y.z literal in the file;
#   C  every ARG in the Dockerfile is a --build-arg in the REMOTE-GATE.md deploy
#      block.
#
# Run from anywhere: tests/testhost-node-install.bh-1617-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
INST="$DIR/fly/testhost/node-install.sh"
DF="$DIR/fly/testhost/Dockerfile"
DOC="$DIR/docs/REMOTE-GATE.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$INST" ] || { echo "FAIL: fly/testhost/node-install.sh does not exist"; exit 1; }
command -v xz >/dev/null || { echo "xz missing — skipping"; exit 0; }

V=22.99.1   # a fixture version: never the row's value, so nothing here pins it
# The fixture is the x64 tarball and every run() pins NODE_ARCH=x64, so the
# suite reads the same on an x86 CI runner and in an arm64 container on a Mac.
ASSET="node-v$V-linux-x64.tar.xz"
mkdir -p "$T/fakebin" "$T/src/node-v$V-linux-x64/bin" "$T/dist/v$V"

# The stub node answers per the STUB_* env the case exports.
cat > "$T/src/node-v$V-linux-x64/bin/node" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo "${STUB_VER:-v__V__}"; exit 0 ;;
  --experimental-strip-types) exit "${STUB_STRIP_RC:-0}" ;;
  -e) case "$2" in *node:sqlite*) exit "${STUB_SQLITE_RC:-0}" ;; esac; exit 0 ;;
esac
exit 0
STUB
sed -i "s/__V__/$V/" "$T/src/node-v$V-linux-x64/bin/node"
chmod 755 "$T/src/node-v$V-linux-x64/bin/node"
echo changelog > "$T/src/node-v$V-linux-x64/CHANGELOG.md"
tar -cJf "$T/dist/v$V/$ASSET" -C "$T/src" "node-v$V-linux-x64"
GOOD_SUM=$(sha256sum "$T/dist/v$V/$ASSET" | awk '{print $1}')

# fakebin curl: serves $T/dist/<path> for https://fixture.test/dist/<path>.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "$url" >> "$CURL_LOG"
f="$FIX_DIST/${url#https://fixture.test/dist/}"
[ -f "$f" ] || exit 22
if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi
CURL
chmod 755 "$T/fakebin/curl"
export CURL_LOG="$T/curl.log" FIX_DIST="$T/dist"

sums() { printf '%s  %s\n' "$1" "$ASSET" > "$T/dist/v$V/SHASUMS256.txt"; }
run() {  # run <case> <version>; sets rc, out, err, P
  P="$T/prefix-$1"; scratch_rm "$P"; mkdir -p "$P"; : > "$CURL_LOG"
  NODE_ARCH=x64 NODE_PREFIX="$P" NODE_DIST="https://fixture.test/dist" PATH="$T/fakebin:$PATH" \
    sh "$INST" "$2" >"$T/out" 2>"$T/err"; rc=$?
  out=$(cat "$T/out"); err=$(cat "$T/err")
}

# A1
sums "$GOOD_SUM"
run a1 ""
[ "$rc" -ne 0 ] && ok || bad "A1 empty version accepted (rc=$rc)"
grep -q NODE_VERSION <<<"$err" && ok || bad "A1 stderr does not name NODE_VERSION: $err"
[ ! -s "$CURL_LOG" ] && ok || bad "A1 downloaded before refusing: $(cat "$CURL_LOG")"

# A2
for bogus in latest 22 22.23 lts 22.23.2.1; do
  run a2 "$bogus"
  [ "$rc" -ne 0 ] && ok || bad "A2 '$bogus' accepted"
  [ ! -s "$CURL_LOG" ] && ok || bad "A2 '$bogus' downloaded before refusing"
done
run a2v "v$V"
[ "$rc" -eq 0 ] && ok || bad "A2 'v$V' refused (rc=$rc): $err"

# A3
sums "0000000000000000000000000000000000000000000000000000000000000000"
run a3 "$V"
[ "$rc" -ne 0 ] && ok || bad "A3 bad digest accepted"
[ ! -e "$P/bin/node" ] && ok || bad "A3 extracted despite a bad digest"
# A3b
printf '%s  %s\n' "$GOOD_SUM" "node-v$V-darwin-arm64.tar.gz" > "$T/dist/v$V/SHASUMS256.txt"
run a3b "$V"
[ "$rc" -ne 0 ] && ok || bad "A3b SHASUMS with no line for the asset accepted"
[ ! -e "$P/bin/node" ] && ok || bad "A3b extracted with no digest line"
sums "$GOOD_SUM"

# A4
STUB_VER=v20.19.2 run a4 "$V"
[ "$rc" -ne 0 ] && ok || bad "A4 wrong node version accepted"
{ grep -q "v20.19.2" <<<"$err" && grep -q "$V" <<<"$err"; } && ok || bad "A4 stderr lacks both versions: $err"
export -n STUB_VER 2>/dev/null; unset STUB_VER

# A5 / A5b
STUB_SQLITE_RC=1 run a5 "$V"
[ "$rc" -ne 0 ] && ok || bad "A5 node without node:sqlite accepted"
grep -q "node:sqlite" <<<"$err" && ok || bad "A5 stderr does not name node:sqlite: $err"
STUB_STRIP_RC=9 run a5b "$V"
[ "$rc" -ne 0 ] && ok || bad "A5b node rejecting --experimental-strip-types accepted"
grep -q -- "--experimental-strip-types" <<<"$err" && ok || bad "A5b stderr does not name --experimental-strip-types: $err"

# A6
run a6 "$V"
[ "$rc" -eq 0 ] && ok || bad "A6 happy path failed (rc=$rc): $err"
[ -x "$P/bin/node" ] && ok || bad "A6 no $P/bin/node"
[ ! -e "$P/CHANGELOG.md" ] && ok || bad "A6 CHANGELOG.md extracted into the prefix"
grep -q "^testhost node: $V " <<<"$out" && ok || bad "A6 stdout lacks 'testhost node: $V': $out"
grep -qx "https://fixture.test/dist/v$V/$ASSET" "$CURL_LOG" && ok || bad "A6 did not fetch the tarball: $(cat "$CURL_LOG")"

# B — the Dockerfile
grep -qxE 'ARG NODE_VERSION' "$DF" && ok || bad "B no bare 'ARG NODE_VERSION' (no default) in the Dockerfile"
grep -qE '^ARG NODE_VERSION=' "$DF" && bad "B ARG NODE_VERSION carries a default" || ok
guard=$(sed -n '/^RUN test -n /,/exit 1; }/p' "$DF" | sed '1s/^RUN //' | sed 's/\\$//' | tr '\n' ' ')
if [ -z "$guard" ]; then
  bad "B no 'RUN test -n' guard found in the Dockerfile"
else
  grep -q NODE_VERSION <<<"$guard" && ok || bad "B the guard does not name NODE_VERSION"
  NODE_VERSION="" CODEGRAPH_VERSION=a SEMGREP_VERSION=b ACTIONLINT_VERSION=c sh -c "$guard" 2>"$T/gerr"; grc=$?
  [ "$grc" -ne 0 ] && ok || bad "B the guard passes with NODE_VERSION empty"
  grep -q NODE_VERSION "$T/gerr" && ok || bad "B the guard's FATAL does not name NODE_VERSION"
  NODE_VERSION=x CODEGRAPH_VERSION=a SEMGREP_VERSION=b ACTIONLINT_VERSION=c sh -c "$guard" 2>/dev/null \
    && ok || bad "B the guard fails with every pin set (the extract is broken)"
fi
apt=$(sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt/p' "$DF")
if [ -z "$apt" ]; then
  bad "B no apt-get install block found"
else
  grep -qwE 'nodejs|npm' <<<"$apt" && bad "B the apt install still names nodejs/npm" || ok
  grep -qw 'xz-utils' <<<"$apt" && ok || bad "B the apt install lacks xz-utils (tar -J)"
fi
ni=$(grep -n 'testhost-node-install.sh "\$NODE_VERSION"' "$DF" | grep '^[0-9]*:RUN' | head -1 | cut -d: -f1)
npmg=$(grep -n 'npm install -g' "$DF" | head -1 | cut -d: -f1)
if [ -z "$ni" ] || [ -z "$npmg" ]; then
  bad "B node-install RUN (${ni:-missing}) or npm install -g (${npmg:-missing}) not found"
else
  [ "$ni" -lt "$npmg" ] && ok || bad "B node is installed (line $ni) after npm install -g (line $npmg)"
fi
grep -q 'COPY node-install.sh /usr/local/bin/testhost-node-install.sh' "$DF" && ok || bad "B node-install.sh is not copied into the image"
lit=$(grep -nE '[0-9]+\.[0-9]+\.[0-9]+' "$DF")
[ -z "$lit" ] && ok || bad "B version literal in the Dockerfile: $lit"

# C — the deploy block passes every ARG
block=$(awk '/^## Deploying the test host image/{s=1} s&&/^```sh/{b=1;next} b&&/^```/{exit} b' "$DOC")
if [ -z "$block" ]; then
  bad "C no deploy block under '## Deploying the test host image' in docs/REMOTE-GATE.md"
else
  args=$(grep -E '^ARG ' "$DF" | awk '{print $2}' | cut -d= -f1)
  [ -n "$args" ] || bad "C no ARG found in the Dockerfile"
  for a in $args; do
    grep -q -- "--build-arg $a=" <<<"$block" && ok || bad "C the deploy block does not pass --build-arg $a="
  done
fi

echo "testhost-node-install (BH-1617): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
