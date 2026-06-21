#!/bin/bash
# #143 premature-free CULPRIT probe.  Build 12-19/-j8, QEMU 16-19, oracle -smp 8.
# Catches: (fm) folio freed while folio_mapped() true -> dump_stack NAMES the
# ref-dropper culprit; (wp) order-0 remove on an already-freed folio (dangling
# PTE aftermath).  Goal: identify the path that frees a still-mapped cluster.
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
BZ=$D/bzImage-fmdiag

echo "=== BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -3
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged $(basename "$BZ") $(stat -c %s "$BZ")"

for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$BZ" "$D/fmdiag-$r.log" 220 8 >/dev/null 2>&1
  L=$D/fmdiag-$r.log
  fm=$(grep -ac 'PGCL#143fm: FREED-WHILE-MAPPED' "$L")
  wp=$(grep -ac 'PGCL#143wp: order-0 UNDERFLOW' "$L")
  echo "run$r: freed_mapped=$fm remove_on_freed=$wp | login=$(grep -ac 'login:' "$L") panic=$(grep -ac 'Kernel panic' "$L") badpage=$(grep -ac 'Bad page' "$L")"
done
echo "=== fmdiag done $(date +%H:%M:%S) ==="
