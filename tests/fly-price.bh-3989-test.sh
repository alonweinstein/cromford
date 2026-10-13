#!/bin/bash
# tests/fly-price.bh-3989-test.sh — BH-4018 (split child 1 of #3989): pins
# fly_price_per_s in bin/lib/fly-cost-row.sh, the per-second Fly price every
# sibling of #3989 sources. Asserts printed values and return codes, and pins
# the formula to poll_fly's in bin/vendor-spend-pull.sh by running that file's
# own python (A6), so the duplicate cannot drift.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LIB="$DIR/bin/lib/fly-cost-row.sh"
VSP="$DIR/bin/vendor-spend-pull.sh"
P="$DIR/catalog/fly-prices.json"
. "$LIB" || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
r9()  { python3 -c "import sys; print(f'{round(float(sys.argv[1]), 9):.9f}')" "$1"; }

if ! command -v fly_price_per_s >/dev/null 2>&1; then
  echo "FAIL: fly_price_per_s not defined after sourcing $LIB"
  echo "fly-price: 0 passed, 1 failed"; exit 1
fi

SPM=$(jq -r '.seconds_per_month' "$P")
PERF=$(jq -r '.cpu_usd_per_core_month.performance' "$P")
SHR=$(jq -r '.cpu_usd_per_core_month.shared' "$P")
MEM=$(jq -r '.memory_usd_per_gb_month' "$P")
want_perf=$(python3 -c "print(f'{round((8*$PERF + 16*$MEM)/$SPM, 9):.9f}')")
want_shr=$(python3 -c "print(f'{round((1*$SHR + 0.25*$MEM)/$SPM, 9):.9f}')")

# A1a: performance 8 16384 from the committed catalog.
out=$(fly_price_per_s "$P" performance 8 16384); rc=$?
eq "A1a rc" 0 "$rc"
eq "A1a price" "$want_perf" "$(r9 "${out%% *}")"
eq "A1a source" catalog "${out##* }"
A1=${out%% *}

# A1b: shared 1 256.
out=$(fly_price_per_s "$P" shared 1 256); rc=$?
eq "A1b rc" 0 "$rc"
eq "A1b price" "$want_shr" "$(r9 "${out%% *}")"
eq "A1b source" catalog "${out##* }"

# A3a: a fixture catalog with performance 62.0 doubles the CPU part.
jq '.cpu_usd_per_core_month.performance = 62.0' "$P" > "$T/p62.json"
out=$(fly_price_per_s "$T/p62.json" performance 8 16384); rc=$?
eq "A3a rc" 0 "$rc"
eq "A3a cpu part doubled" "$(python3 -c "print(f'{round(2*8*$PERF/$SPM, 9):.9f}')")" \
  "$(python3 -c "print(f'{round(${out%% *} - 16*$MEM/$SPM, 9):.9f}')")"
eq "A3a source" catalog "${out##* }"

# A3b: missing / empty / unparseable / key-less catalogs all price from the
# fallback, with the same number as A1a (the fallback carries the list prices).
printf '{}' > "$T/empty.json"
printf 'not json' > "$T/bad.json"
jq 'del(.memory_usd_per_gb_month)' "$P" > "$T/nomem.json"
for c in "$T/missing.json" "" "$T/empty.json" "$T/bad.json" "$T/nomem.json"; do
  out=$(fly_price_per_s "$c" performance 8 16384); rc=$?
  eq "A3b rc [$c]" 0 "$rc"
  eq "A3b price [$c]" "$want_perf" "$(r9 "${out%% *}")"
  eq "A3b source [$c]" fallback "${out##* }"
done

# A4: kind is lowercased; unknown and empty kinds take the shared rate.
eq "A4 PERFORMANCE" "$A1" "$(fly_price_per_s "$P" PERFORMANCE 8 16384 | cut -d' ' -f1)"
shr8=$(fly_price_per_s "$P" shared 8 16384 | cut -d' ' -f1)
[ -n "$shr8" ] && [ "$shr8" != "$A1" ] && ok || bad "A4 shared 8 16384 should differ from performance: [$shr8]"
eq "A4 a100" "$shr8" "$(fly_price_per_s "$P" a100 8 16384 | cut -d' ' -f1)"
eq "A4 empty kind" "$shr8" "$(fly_price_per_s "$P" "" 8 16384 | cut -d' ' -f1)"

# A5-price: unknown size is rc 1 with nothing printed, never $0 (D11).
for c in "|256" "abc|256" "0|256" "-2|256" "0.0|256" "1|" "1|x" "1|0" "1|-512" "1|1e3"; do
  out=$(fly_price_per_s "$P" shared "${c%%|*}" "${c#*|}"); rc=$?
  eq "A5 rc [$c]" 1 "$rc"
  eq "A5 stdout [$c]" "" "$out"
done
# Fractional sizes are real sizes.
out=$(fly_price_per_s "$P" shared 0.5 512.0); rc=$?
eq "A5 fractional rc" 0 "$rc"
eq "A5 fractional price" "$(python3 -c "print(f'{round((0.5*$SHR + 0.5*$MEM)/$SPM, 9):.9f}')")" "$(r9 "${out%% *}")"

# A6 parity: run poll_fly's own python from vendor-spend-pull.sh — the rate
# block and its per-machine usd line — over a 6h window, against
# fly_price_per_s x window. An empty extraction FAILS, so a refactor of
# vendor-spend-pull cannot silently switch the parity off.
rates=$(sed -n "/^FALLBACK = /,/^MEM_RATE = /p" "$VSP")
usd_line=$(grep -m1 -E '^[[:space:]]+usd \+= secs \* cpus \* cpu_rate\(' "$VSP" | sed 's/^[[:space:]]*//')
if [ -z "$rates" ] || [ -z "$usd_line" ]; then
  bad "A6 could not extract poll_fly's formula from $VSP (rates=${#rates} usd_line=${#usd_line})"
else
  { printf 'import json, sys\nprices_path = sys.argv[1]\n%s\n' "$rates"
    printf 'g = {"cpu_kind": sys.argv[2], "cpus": int(sys.argv[3]), "memory_mb": int(sys.argv[4])}\n'
    printf 'secs = 21600.0\ncpus = float(g.get("cpus") or 0)\ngb = float(g.get("memory_mb") or 0) / 1024.0\nusd = 0.0\n'
    printf '%s\nprint(f"{usd:.6f}")\n' "$usd_line"
  } > "$T/poll_fly.py"
  for guest in "performance 8 16384" "shared 1 256" "shared 2 4096"; do
    # shellcheck disable=SC2086
    want=$(python3 "$T/poll_fly.py" "$P" $guest); prc=$?
    # shellcheck disable=SC2086
    got=$(fly_price_per_s "$P" $guest | cut -d' ' -f1)
    eq "A6 poll_fly ran [$guest]" 0 "$prc"
    eq "A6 parity [$guest]" "$want" "$(python3 -c "print(f'{float(\"$got\")*21600:.6f}')" 2>/dev/null)"
  done
fi

# A7: cost-row.sh rides along (guarded), and the lib still prices without it.
[ -n "${COST_ROW_HDR:-}" ] && ok || bad "A7 COST_ROW_HDR empty after sourcing"
eq "A7 cost_csv_field" "a b" "$(cost_csv_field 'a,b' 2>/dev/null)"
mkdir -p "$T/solo"; cp "$LIB" "$T/solo/fly-cost-row.sh"
out=$(env -u COST_ROW_HDR bash -c '. "$1" || exit 9; fly_price_per_s "$2" performance 8 16384' _ "$T/solo/fly-cost-row.sh" "$P"); rc=$?
eq "A7 solo rc" 0 "$rc"
eq "A7 solo price" "$want_perf" "$(r9 "${out%% *}" 2>/dev/null)"

# M1 mutation (D1): a lib with + -> * in the usd expression, or /1024 -> /1000,
# must price A1a differently, so this suite would go red on either.
for m in 's/) + (mem/) * (mem/' 's#mem / 1024#mem / 1000#'; do
  sed "$m" "$LIB" > "$T/solo/mut.sh"
  if cmp -s "$LIB" "$T/solo/mut.sh"; then bad "M1 mutation [$m] did not apply"; continue; fi
  mut=$(bash -c '. "$1"; fly_price_per_s "$2" performance 8 16384' _ "$T/solo/mut.sh" "$P" | cut -d' ' -f1)
  [ -n "$mut" ] && [ "$(r9 "$mut")" != "$want_perf" ] && ok || bad "M1 mutation [$m] still prices $mut"
done

echo "fly-price: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
