#!/bin/bash
# matrix-column.sh: run ONE config column (default PGCL=6) across all 16 arches
# via matrix-driver-all.sh — a wider-area smoke without the full 80-cell cost.
#
# Waits for any in-flight bv-v71.sh build smoke to finish first, so the per-cell
# QEMU timeouts (calibrated for PAR=2 load in matrix-driver-all.sh) aren't skewed
# by extra build load on the host.
#
# Usage: matrix-column.sh [CONFIG]     env: PAR=N (default 2), LX=path
set -u
export PATH="/usr/bin:$PATH"
D=/home/nyc/src/pgcl
DRV="$D/matrix-driver-all.sh"
LX=${LX:-/home/nyc/src/linux}
CFG=${1:-6}
export PAR=${PAR:-2}
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$D/matrix-col${CFG}-$TS"
mkdir -p "$OUTDIR"
exec >>"$OUTDIR/column.log" 2>&1

# Don't fight the build smoke for cores (keeps timeouts honest).
waited=0
while pgrep -f '[b]v-v71.sh' >/dev/null 2>&1; do sleep 30; waited=$((waited+30)); done
echo "matrix-column: waited ${waited}s for bv-v71; start CONFIG=$CFG PAR=$PAR LX=$LX @ $(date)"

# or1k+xtensa build+boot here; sh4/csky auto-SKIP (driver) until their toolchain
# (+ qemu-system-csky) is installed.
ARCHES="x86_64 aarch64 riscv64 ppc64 s390x sparc64 loongarch64 alpha riscv32 m68k hppa mips64 arm arm-lpae hppa64 microblaze or1k xtensa sh4 csky"
for A in $ARCHES; do printf '%s %s %s\n' "$LX" "$A" "$CFG"; done > "$OUTDIR/cells.txt"
echo "cells=$(wc -l <"$OUTDIR/cells.txt") OUTDIR=$OUTDIR"

export DRV OUTDIR
< "$OUTDIR/cells.txt" xargs -n3 -P "$PAR" bash -c '"$DRV" "$0" "$1" "$2" "$OUTDIR"'

echo "matrix-column: cells done @ $(date)"
{
  for A in $ARCHES; do
    L="$OUTDIR/${A}_${CFG}.log"
    if [ ! -f "$L" ]; then printf '%-12s NO-LOG\n' "$A"; continue; fi
    if grep -q 'BUILD FAIL\|DEFCONFIG FAIL' "$L"; then st=BUILD-FAIL
    else st="rc=$(sed -n 's/.*QEMU exited rc=\([0-9]*\).*/\1/p' "$L" | tail -1)"; fi
    sig=$(grep -ciE 'panic|Oops|BUG:|Call Trace|segfault' "$L")
    printf '%-12s %-12s warns/crashes:%s\n' "$A" "$st" "$sig"
  done
} | tee "$OUTDIR/SUMMARY.txt"
echo "matrix-column: DONE OUTDIR=$OUTDIR"
