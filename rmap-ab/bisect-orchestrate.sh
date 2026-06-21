#!/bin/bash
# Wait for the position-17 anchor (12241c4d) verdict, then auto-run git bisect
# over [12241c4d..0aceb3e] for the #143 order-0 rmap-underflow race.
set -u
D=/home/nyc/src/pgcl
LX=/home/nyc/src/linux
GOOD=12241c4d0593
BAD=0aceb3e9864a

echo "=== waiting for anchor verdict (anchor-pos17.out) ==="
for i in $(seq 1 90); do
	grep -qaE '^(GOOD|BAD|SKIP)' "$D/rmap-ab/anchor-pos17.out" 2>/dev/null && break
	sleep 60
done
V=$(grep -aE '^(GOOD|BAD|SKIP)' "$D/rmap-ab/anchor-pos17.out" 2>/dev/null | tail -1)
echo "ANCHOR 12241c4d: ${V:-<timeout>}"

if ! echo "$V" | grep -qa '^GOOD'; then
	echo "=== anchor is NOT good -> bug predates the MMUPAGE-unit conversion; need an older anchor. NOT bisecting. ==="
	exit 1
fi

cd "$LX" || exit 1
git bisect reset >/dev/null 2>&1
git bisect start
git bisect bad  "$BAD"
git bisect good "$GOOD"
echo "=== git bisect run starting ($(date +%H:%M:%S)) ==="
git bisect run bash "$D/rmap-ab/bisect-test.sh" > "$D/rmap-ab/bisect-run.log" 2>&1
echo "=== BISECT COMPLETE ($(date +%H:%M:%S)) ==="
echo "--- first-bad-commit / tail of bisect-run.log ---"
grep -aE 'first bad commit|is the first bad commit' "$D/rmap-ab/bisect-run.log" || tail -8 "$D/rmap-ab/bisect-run.log"
echo "--- git bisect log ---"
git bisect log | tail -25
