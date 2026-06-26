#!/bin/bash
# #143 VADDR-KEYED install-attribution.  Build 12-19/-j8, QEMU 16-19 -smp 8.
# On the dangling-remove underflow, pgcl_va_dump() prints the install ADDs the
# cluster-keyed bucket retained for the dangling cluster's vaddr -- which SURVIVE
# the victim pfn's free+reuse (keyed by vaddr, not pfn) -- so the retained add
# whose pfn == the victim names the path (tag) that created the no-ref dangling
# PTE.  Greps PGCL#143va (and the >>> culprit line) on top of wp/fm/tl.
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
BZ=$D/bzImage-va

echo "=== BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -4
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged $(basename "$BZ") $(stat -c %s "$BZ")"

# Build done -> relaunch the orphaned sourcehut full-repo push on 12-15 (leaves
# 16-19 for QEMU), detached so it survives session/API interruptions.
setsid taskset -c 12-15 bash "$D/push-srht-kernel.sh" >> "$D/srht-kernel-push.out" 2>&1 < /dev/null &
echo "push relaunched (setsid, 12-15) -> srht-kernel-push.out"

for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$BZ" "$D/va-$r.log" 220 8 >/dev/null 2>&1
  L=$D/va-$r.log
  wp=$(grep -ac 'PGCL#143wp: order-0 UNDERFLOW' "$L")
  fm=$(grep -ac 'PGCL#143fm: FREED-WHILE-MAPPED' "$L")
  tl=$(grep -ac 'PGCL#143tl: timeline' "$L")
  va=$(grep -ac 'PGCL#143va:' "$L")
  vh=$(grep -ac '>>> ts=' "$L")
  echo "run$r: underflow=$wp fm=$fm tl=$tl va=$va culprit=$vh | login=$(grep -ac 'login:' "$L") panic=$(grep -ac 'Kernel panic' "$L")"
done
echo "=== va done $(date +%H:%M:%S) ==="
