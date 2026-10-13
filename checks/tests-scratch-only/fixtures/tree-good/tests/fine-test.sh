#!/bin/bash
# A ported test: preamble, then the lib, then everything else.
# rm -rf "$HARNESS" written in a comment is documentation, not a deletion.

set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh"
mkdir -p "$T/x" "$T/y" "$T/z"
rm -rf "$T/x"
rm -rf "${T}/y"
D="$T/z"
scratch_rm "$D"
cat > "$T/fixture.sh" <<'EOF'
rm -rf "$H"
EOF
printf 'rm -rf /root/harness\n' > "$T/note.txt"
echo "$DIR" > "$T/where.txt"
