#!/bin/bash
# matrix-dispatch-all.sh: drive matrix-driver-all.sh over the full 16-arch ×
# 5-config (mainline, 0, 2, 4, 6) = 80-cell matrix.
#
# Builds + tests each cell, deletes per-cell build dir on completion.
# Final output: $OUTDIR/${ARCH}_${CONFIG}.log per cell (~tens of KB) +
# $OUTDIR/cells.txt manifest.
#
# Usage: matrix-dispatch-all.sh [PAR=N]   (default PAR=2)

set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
DRV="$D/matrix-driver-all.sh"
LX_PGCL=/home/nyc/src/linux
LX_MAIN=/home/nyc/src/linux-mainline
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$D/matrix-all-$TS"
PAR=${PAR:-2}

mkdir -p "$OUTDIR"
echo "matrix-dispatch-all: OUTDIR=$OUTDIR PAR=$PAR" >&2

# 16 established arches + new bring-up arches. or1k/xtensa build+boot here;
# sh4/csky auto-SKIP in the driver until their toolchain (+ qemu-system-csky)
# is installed on the host.
ARCHES_ALL="x86_64 aarch64 riscv64 ppc64 s390x sparc64 loongarch64 alpha riscv32 m68k hppa mips64 arm arm-lpae hppa64 microblaze or1k xtensa sh4 csky"
CONFIGS_ALL="mainline 0 2 4 6"

# Build cell list: schedule mainline first (warms cache, then PGCL configs reuse
# the linux source tree's ccache state), then each PGCL config.
{
  for CFG in $CONFIGS_ALL; do
    if [ "$CFG" = "mainline" ]; then
      LX="$LX_MAIN"
    else
      LX="$LX_PGCL"
    fi
    for ARCH in $ARCHES_ALL; do
      printf '%s %s %s\n' "$LX" "$ARCH" "$CFG"
    done
  done
} > "$OUTDIR/cells.txt"

CELLS=$(wc -l < "$OUTDIR/cells.txt")
echo "cells: $CELLS" >&2
cat "$OUTDIR/cells.txt" >&2
echo "---" >&2

export DRV OUTDIR
< "$OUTDIR/cells.txt" xargs -n3 -P "$PAR" \
    bash -c '"$DRV" "$0" "$1" "$2" "$OUTDIR"'

echo "matrix-dispatch-all: done; logs in $OUTDIR" >&2
ls -la "$OUTDIR" >&2
