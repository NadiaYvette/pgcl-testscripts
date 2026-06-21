#!/bin/bash
# Split-PTE-ptlock A/B.  CPU layout: Telix=0-9 (leave alone), 10-11=interaction/
# Claude shells, 12-19=pgcl (mine).  Build uses all of 12-19 (-j8); QEMU uses the
# 16-19 subset at -smp 8 (2x oversub -- the proven race-catch config, NOT idle
# cores).  Launch under `taskset -c 12-19` so wrapper+olddefconfig stay in 12-19,
# off Telix.  Reuses the already-built bzImage-clean-base (arm A).
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab

summ() { local L="$1"
  echo "rr=$(grep -ac 'RR start' "$L")/$(grep -ac 'RR DONE' "$L") login=$(grep -ac 'login:' "$L") panic=$(grep -ac 'Kernel panic' "$L") killinit=$(grep -ac 'kill init' "$L") badpage=$(grep -ac 'Bad page' "$L") kbug=$(grep -ac 'kernel BUG at\|BUG: unable\|general protection' "$L")"
}

echo "=== arm A (SPLIT=y, reuse bzImage-clean-base) $(date +%H:%M:%S) ==="
echo "--- A control: smp1 x3 (expect clean) ---"
for r in 1 2 3; do
  bash "$D/run-rr.sh" "$D/bzImage-clean-base" "$D/sp2-base-s1-$r.log" 220 1 >/dev/null 2>&1
  printf "  base smp1 run%s: " "$r"; summ "$D/sp2-base-s1-$r.log"
done
echo "--- A oracle: smp8 x8 (expect ~6/8 die) ---"
for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$D/bzImage-clean-base" "$D/sp2-base-s8-$r.log" 220 8 >/dev/null 2>&1
  printf "  base smp8 run%s: " "$r"; summ "$D/sp2-base-s8-$r.log"
done

echo "=== disable SPLIT_PTE_PTLOCKS under PGCL (Kconfig) $(date +%H:%M:%S) ==="
sed -i '/depends on !S390 || PAGE_MMUSHIFT = 0/a\\tdepends on PAGE_MMUSHIFT = 0' "$SRC/mm/Kconfig"
( cd "$SRC" && make O="$O" olddefconfig >/dev/null 2>&1 )
grep -E "CONFIG_SPLIT_PTE_PTLOCKS|CONFIG_SPLIT_PMD_PTLOCKS" "$O/.config" || echo "SPLIT now unset (good)"

echo "=== arm B build: taskset 12-19, -j8 $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -3
rc=${PIPESTATUS[0]}
echo "BUILD clean-nosplit rc=$rc $(date +%H:%M:%S)"
if [ "$rc" = 0 ]; then
  cp "$O/arch/x86/boot/bzImage" "$D/bzImage-clean-nosplit"
  echo "staged bzImage-clean-nosplit ($(stat -c %s "$D/bzImage-clean-nosplit"))"
  echo "--- B oracle: smp8 x8 (does it go clean?) ---"
  for r in 1 2 3 4 5 6 7 8; do
    bash "$D/run-rr.sh" "$D/bzImage-clean-nosplit" "$D/sp2-nosplit-s8-$r.log" 220 8 >/dev/null 2>&1
    printf "  nosplit smp8 run%s: " "$r"; summ "$D/sp2-nosplit-s8-$r.log"
  done
else
  echo "BUILD clean-nosplit FAILED"
fi

( cd "$SRC" && git checkout mm/Kconfig )
echo "=== split-ptl A/B (throttled) done $(date +%H:%M:%S); Kconfig restored ==="
