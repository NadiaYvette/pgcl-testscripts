#!/bin/bash
# build-run-143probe.sh — build the #143 MIGRATE-PAIR probe kernel and run it on
# the live -smp8 oracle.  Probe = VM_WARN_ON(folio_mapcount > folio_ref_count) at
# migrate-out (try_to_migrate_one, after folio_put_refs) and migrate-in
# (remove_migration_pte, after restore).  Fires only on a mapping-without-a-ref
# (the freed-while-mapped precursor).  Also confirms the rmap.c:1620/1635
# anon-exclusive WARNs are now silenced by the PGCL guard (#146 commit).
set -u
SRC=/home/nyc/src/linux; O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
echo "=== build #143 migrate-pair probe kernel $(date +%T) (branch $(git -C "$SRC" rev-parse --abbrev-ref HEAD)) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -6
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "KERNEL-FAIL rc=$rc"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$D/bzImage-143probe" && echo "OK -> bzImage-143probe $(date +%T)"
echo "=== run probe on live -smp8 oracle (4x, 240s) $(date +%T) ==="
cd "$D"
BZ="$D/bzImage-143probe" bash run-smp8-trip.sh 4 240
echo
echo "=== PROBE VERDICT ==="
for L in "$D"/trip-*.log; do
  [ -f "$L" ] || continue
  mig=$(grep -acE 'try_to_migrate_one|remove_migration_pte' "$L")
  oldwarn=$(grep -acE 'mm/rmap\.c:(1620|1635)|1620 at folio_add_anon_rmap|1635 at folio_add_anon_rmap' "$L")
  ki=$(grep -acE 'kill init|Attempted to kill init' "$L")
  probe=$(grep -aoE 'WARNING: mm/(rmap|migrate)\.c:[0-9]+ at (try_to_migrate_one|remove_migration_pte)' "$L" | sort -u | tr '\n' ' ')
  echo "$(basename "$L"): killinit=$ki | migrate-pair-PROBE=[$probe] | old-1620/1635-warns=$oldwarn"
done
echo "--- first migrate-pair probe block (the imbalance in flagrante), if any ---"
for L in "$D"/trip-*.log; do
  grep -aqE 'at (try_to_migrate_one|remove_migration_pte)' "$L" 2>/dev/null || continue
  echo ">>> $L"; grep -anA16 -E 'WARNING: mm/(rmap|migrate)\.c:[0-9]+ at (try_to_migrate_one|remove_migration_pte)' "$L" | head -20; break
done
echo "=== DONE $(date +%T) ==="
