#!/bin/bash
# #143 NON-PERTURBING per-CPU race-catcher.  Build 12-19/-j8, QEMU 16-19, -smp 8.
# On an order-0 underflow (wp) or freed-while-mapped (fm), dumps the cross-CPU
# mapcount-event TIMELINE (tl) for the victim pfn -- per-CPU rings, no shared
# atomics, so the tight cross-mm race is NOT suppressed.
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
BZ=$D/bzImage-tldiag

echo "=== BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -3
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged $(basename "$BZ") $(stat -c %s "$BZ")"

for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$BZ" "$D/tldiag-$r.log" 220 8 >/dev/null 2>&1
  L=$D/tldiag-$r.log
  wp=$(grep -ac 'PGCL#143wp: order-0 UNDERFLOW' "$L")
  fm=$(grep -ac 'PGCL#143fm: FREED-WHILE-MAPPED' "$L")
  tl=$(grep -ac 'PGCL#143tl: timeline' "$L")
  echo "run$r: underflow=$wp freed_mapped=$fm timelines=$tl | login=$(grep -ac 'login:' "$L") panic=$(grep -ac 'Kernel panic' "$L")"
done
echo "=== tldiag done $(date +%H:%M:%S) ==="
