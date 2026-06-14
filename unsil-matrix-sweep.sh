#!/bin/bash
# Full UN-SILENCED matrix sweep: validate the corruption-detector masker removal
# (commit a8dbfe2b0fa8) + all recent fixes across every arch.  Runs DEBUG_VM +
# DEBUG_VM_PGFLAGS + PAGE_OWNER (BIGRAM_DEBUG=1) with page_owner=on so any
# bad-free / negative-mapcount / bad-pte fires and is attributed.
# Chained: waits for the pgcl0-unsil RPM build to finish first so the two heavy
# builds don't contend (the laptop testboot RPM has priority).
set -u
LX=/home/nyc/src/linux
D=/home/nyc/src/pgcl
OUT="$D/unsil-matrix-$(cat $D/.unsil-stamp 2>/dev/null || echo run)"
OUT="$D/unsil-matrix-out"; mkdir -p "$OUT"
SUM="$OUT/SUMMARY.txt"; : > "$SUM"

# 1) wait for the RPM build to release the machine
echo "$(date +%H:%M:%S) waiting for pgcl0-unsil RPM build to finish..." | tee -a "$SUM"
until grep -qE 'pgcl0-unsil RPM DONE|BUILD FAIL' "$D/build-pgcl0-unsil-rpm.out" 2>/dev/null; do sleep 30; done
echo "$(date +%H:%M:%S) RPM build released; starting un-silenced sweep" | tee -a "$SUM"

ARCHES="x86_64 aarch64 riscv64 ppc64 s390x sparc64 loongarch64 alpha riscv32 m68k hppa mips64 arm arm-lpae hppa64 microblaze"
CONFIGS="0 4 6"

for A in $ARCHES; do
  for C in $CONFIGS; do
    cell="${A}_${C}"
    echo "######## CELL $cell START $(date +%H:%M:%S) ########" | tee -a "$SUM"
    BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on" MATRIX_J=20 \
      bash "$D/matrix-driver-all.sh" "$LX" "$A" "$C" "$OUT" >/dev/null 2>&1
    L="$OUT/${A}_${C}.log"
    real=$(grep -ciE 'Bad page state|kernel BUG at|invalid opcode|VM_BUG|bad_page|free_page_is_bad|print_bad_pte|still mapped|nonzero (map|ref)count|Attempted to kill init' "$L" 2>/dev/null || echo 0)
    ltp=$(grep -oE 'LTP subtotals:.*' "$L" 2>/dev/null | tail -1)
    init=$(grep -qE 'Run /init as init process' "$L" 2>/dev/null && echo init-ok || echo NO-INIT)
    verdict="markers=$real $init | ${ltp:-<no LTP line>}"
    echo ">>> CELL $cell: $verdict" | tee -a "$SUM"
  done
done
echo "######## UNSIL SWEEP DONE $(date +%H:%M:%S) ########" | tee -a "$SUM"
echo "=== cells with real markers>0 or NO-INIT (need attention) ===" | tee -a "$SUM"
grep -E '>>> CELL' "$SUM" | grep -vE 'markers=0 init-ok' | tee -a "$SUM"
