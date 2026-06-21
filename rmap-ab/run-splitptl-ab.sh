#!/bin/bash
# Split-PTE-ptlock A/B on the CLEAN tree (HEAD + the 2 real fixes, NO debug).
# A = SPLIT_PTE_PTLOCKS=y (stock), B = SPLIT off under PGCL (mm-wide page_table_lock).
# Oracle signal only (DEBUG_VM catches the underflow): Bad page / kernel BUG / panic.
# Hypothesis: B clean & A dies => same-mm (cross-table) race; B still dies => cross-mm.
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab

summ() { # $1=logfile  -> one summary line
  local L="$1"
  echo "rr=$(grep -ac 'RR start' "$L")/$(grep -ac 'RR DONE' "$L") login=$(grep -ac 'login:' "$L") panic=$(grep -ac 'Kernel panic' "$L") killinit=$(grep -ac 'kill init' "$L") badpage=$(grep -ac 'Bad page' "$L") kbug=$(grep -ac 'kernel BUG at\|BUG: unable\|general protection' "$L")"
}

build() { # $1=tag -> builds + stages bzImage-$1
  echo "=== BUILD $1 start $(date +%H:%M:%S) ==="
  taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -3
  local rc=${PIPESTATUS[0]}
  echo "BUILD $1 rc=$rc $(date +%H:%M:%S)"
  [ "$rc" = 0 ] || { echo "BUILD $1 FAILED"; exit 1; }
  cp "$O/arch/x86/boot/bzImage" "$D/bzImage-$1"
  echo "staged bzImage-$1 ($(stat -c %s "$D/bzImage-$1"))"
}

# ---------- arm A: SPLIT=y (stock) ----------
grep -q "CONFIG_SPLIT_PTE_PTLOCKS=y" "$O/.config" && echo "config: SPLIT=y (baseline)"
build clean-base
echo "--- A control: smp1 x3 (expect clean) ---"
for r in 1 2 3; do
  bash "$D/run-rr.sh" "$D/bzImage-clean-base" "$D/sp-base-s1-$r.log" 220 1 >/dev/null 2>&1
  printf "  base smp1 run%s: " "$r"; summ "$D/sp-base-s1-$r.log"
done
echo "--- A oracle: smp8 x8 (expect ~6/8 die) ---"
for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$D/bzImage-clean-base" "$D/sp-base-s8-$r.log" 220 8 >/dev/null 2>&1
  printf "  base smp8 run%s: " "$r"; summ "$D/sp-base-s8-$r.log"
done

# ---------- flip Kconfig: disable SPLIT_PTE_PTLOCKS under PGCL ----------
echo "=== disabling SPLIT_PTE_PTLOCKS under PGCL (Kconfig) $(date +%H:%M:%S) ==="
sed -i '/depends on !S390 || PAGE_MMUSHIFT = 0/a\\tdepends on PAGE_MMUSHIFT = 0' "$SRC/mm/Kconfig"
( cd "$SRC" && make O="$O" olddefconfig >/dev/null 2>&1 )
grep -E "CONFIG_SPLIT_PTE_PTLOCKS|CONFIG_SPLIT_PMD_PTLOCKS" "$O/.config" || echo "SPLIT now unset (good)"

# ---------- arm B: SPLIT=n ----------
build clean-nosplit
echo "--- B oracle: smp8 x8 (does it go clean?) ---"
for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$D/bzImage-clean-nosplit" "$D/sp-nosplit-s8-$r.log" 220 8 >/dev/null 2>&1
  printf "  nosplit smp8 run%s: " "$r"; summ "$D/sp-nosplit-s8-$r.log"
done

# ---------- restore Kconfig ----------
( cd "$SRC" && git checkout mm/Kconfig )
echo "=== split-ptl A/B done $(date +%H:%M:%S) (Kconfig restored; O .config left at SPLIT=n) ==="
