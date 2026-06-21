#!/bin/bash
# Confirming probe: ring5-fix tree + remove-side vaddr stash (pgcl_rm_va).
# Goal: for an over-remove pfn (e.g. order-0 anon 6628: 2 adds, 4 removes),
# are the surplus removes at the SAME vaddr (concurrent double-remove of ONE
# sub-PTE) or DIFFERENT vaddrs?  Build, stage, then 8x at the proven catch
# config (-smp 8 on the isolated E-cores, 2x oversub).
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
BZ=$D/bzImage-ring6va

echo "=== BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -4
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED — aborting"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged: $(stat -c %s "$BZ") $(basename "$BZ")"

for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$BZ" "$D/rr-ring6va-$r.log" 220 8 >/dev/null 2>&1
  L=$D/rr-ring6va-$r.log
  echo "run$r: anomaly=$(grep -ac 'PGCL#143: ===== anomaly' "$L") SUM=$(grep -ac 'PGCL#143:   SUM' "$L") freed=$(grep -aE 'PGCL#143: folio=' "$L" | grep -ac 'refcount=0 ') large=$(grep -ac 'LARGE _large' "$L") filemap=$(grep -ac 'mapped@truncate' "$L") badpage=$(grep -ac 'Bad page state' "$L") panic=$(grep -ac 'Kernel panic' "$L") login=$(grep -ac 'login:' "$L")"
done
echo "=== ring6va done $(date +%H:%M:%S) ==="
