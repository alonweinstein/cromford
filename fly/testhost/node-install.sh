#!/bin/sh
# fly/testhost/node-install.sh — install the node CI runs onto the test-host
# image (BH-1617). The Dockerfile passes NODE_VERSION, the bake.node.version
# row: the same row fly/Dockerfile bakes into the builder image.
#
#   node-install.sh <version>      e.g. the row's x.y.z (a leading v is dropped)
#
# Debian's apt nodejs is a node 20. On it jobs-worker-test has no node:sqlite and
# repro-gate-test's fixtures cannot run --experimental-strip-types, so this
# refuses to finish unless the installed node reports <version> AND has both.
# Those are capability probes, not a minimum version, so no version literal
# lives here.
#
# The tarball matches the machine: linux-x64 on the Fly test hosts, linux-arm64
# in bin/run-tests-in-docker.sh's image on an Apple-silicon Mac, which installs
# node with this same script.
#
# Test seams: NODE_PREFIX (install prefix, default /usr/local), NODE_DIST
# (download base, default https://nodejs.org/dist) and NODE_ARCH (the nodejs.org
# arch name, default from `uname -m`).
set -eu
die() { echo "FATAL: $*" >&2; exit 1; }

V="${1:-}"
V="${V#v}"
[ -n "$V" ] || die "no node version: pass --build-arg NODE_VERSION=<the bake.node.version row> (docs/REMOTE-GATE.md)"
echo "$V" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' \
  || die "NODE_VERSION '$1' is not an exact x.y.z (the bake.node.version row)"

PREFIX="${NODE_PREFIX:-/usr/local}"
DIST="${NODE_DIST:-https://nodejs.org/dist}"
ARCH="${NODE_ARCH:-}"
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=x64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "no nodejs.org linux build for machine '$(uname -m)'" ;;
  esac
fi
ASSET="node-v$V-linux-$ARCH.tar.xz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/$ASSET" "$DIST/v$V/$ASSET" || die "download failed: $DIST/v$V/$ASSET"
curl -fsSL -o "$TMP/SHASUMS256.txt" "$DIST/v$V/SHASUMS256.txt" || die "download failed: $DIST/v$V/SHASUMS256.txt"
grep -E "^[0-9a-f]{64}  $ASSET\$" "$TMP/SHASUMS256.txt" > "$TMP/sum" || die "SHASUMS256.txt has no line for $ASSET"
(cd "$TMP" && sha256sum -c --status sum) || die "$ASSET does not match its SHASUMS256.txt digest"

tar -xJf "$TMP/$ASSET" -C "$PREFIX" --strip-components=1 \
  --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'

NODE="$PREFIX/bin/node"
got=$("$NODE" --version 2>&1) || die "installed node does not run: $got"
[ "$got" = "v$V" ] || die "installed node reports $got, expected v$V"
"$NODE" -e "import('node:sqlite').then(()=>{},()=>process.exit(1))" \
  || die "node v$V has no node:sqlite (tests/jobs-worker-test.sh needs it)"
"$NODE" --experimental-strip-types -e 0 \
  || die "node v$V rejects --experimental-strip-types (tests/repro-gate-test.sh needs it)"
echo "testhost node: $V (node:sqlite ok, strip-types ok)"
