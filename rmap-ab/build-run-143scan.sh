#!/bin/bash
# build-run-143scan.sh -- build the #143 STRUCTURAL orphan-PTE scanner kernel
# (mm/pgcl143_ptescan.c kthread + dump_page_owner in print_bad_page_map) and run
# it on the live -smp8 oracle.  A hit dumps the orphaned cluster's page_owner
# FREE stack = the path that freed it while a PTE stayed live = the #143 creator.
set -u
SRC=/home/nyc/src/linux; O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
echo "=== build #143 scanner kernel $(date +%T) (branch $(git -C "$SRC" rev-parse --abbrev-ref HEAD)) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -8
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "KERNEL-FAIL rc=$rc"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$D/bzImage-143scan" && echo "OK -> bzImage-143scan $(date +%T)"
echo "=== run scanner on live -smp8 oracle (4x, 240s) $(date +%T) ==="
cd "$D"
BZ="$D/bzImage-143scan" bash run-smp8-trip.sh 4 240
echo
echo "=== SCANNER VERDICT ==="
for L in "$D"/trip-{1,2,3,4}.log; do
  [ -f "$L" ] || continue
  orphan=$(grep -ac 'PGCL143-ORPHAN' "$L")
  badmap=$(grep -ac 'Bad page map' "$L")
  owner=$(grep -acE 'page last free|page_owner free|page last allocated' "$L")
  ki=$(grep -acE 'kill init|Attempted to kill init' "$L")
  echo "$(basename "$L"): scanner-ORPHAN=$orphan badpagemap=$badmap page_owner-dumps=$owner killinit=$ki"
done
echo
echo "=== first ORPHAN hit + its page_owner FREE stack (the creator), if any ==="
for L in "$D"/trip-{1,2,3,4}.log; do
  grep -aq 'PGCL143-ORPHAN' "$L" 2>/dev/null || continue
  echo ">>> $L"; grep -anA40 'PGCL143-ORPHAN' "$L" | head -44; break
done
echo
echo "=== else: first Bad-page-map + its page_owner FREE stack (teardown-side creator) ==="
for L in "$D"/trip-{1,2,3,4}.log; do
  grep -aq 'Bad page map' "$L" 2>/dev/null || continue
  echo ">>> $L"; grep -anA34 'Bad page map' "$L" | head -38; break
done
echo "=== DONE $(date +%T) ==="
