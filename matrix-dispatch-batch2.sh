#!/bin/bash
# matrix-dispatch-batch2.sh: 7 fast arches × {0,2,6} + slow arches × {mainline,4}
# Run after batch 1 (mainline,4 on fast arches) completes.

set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
# Use the slow driver: 600/900s timeouts (s390x/loongarch64 LTP needs >300s) and
# reuses already-built kbuild dirs.  matrix-driver.sh's bug-fix (no-pkill) was
# also brought into matrix-driver-slow.sh.
DRV="$D/matrix-driver-slow.sh"
LX_PGCL=/home/nyc/src/linux
LX_MAIN=/home/nyc/src/linux-mainline
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$D/matrix-batch2-$TS"
PAR=${PAR:-2}

mkdir -p "$OUTDIR"
echo "matrix-dispatch-batch2: OUTDIR=$OUTDIR PAR=$PAR" >&2

ARCHES_FAST="x86_64 aarch64 riscv64 ppc64 s390x sparc64 loongarch64"
EXTRA_CONFIGS="0 2 6"

# Slow arches (longer timeouts, sequential preferred): not in matrix-driver.sh yet.
# matrix-driver.sh only handles 7 fast arches today; expand later for alpha/m68k/microblaze/etc.

{
  for ARCH in $ARCHES_FAST; do
    for CFG in $EXTRA_CONFIGS; do
      printf '%s %s %s\n' "$LX_PGCL" "$ARCH" "$CFG"
    done
  done
} > "$OUTDIR/cells.txt"

echo "cells:" >&2
cat "$OUTDIR/cells.txt" >&2

export DRV OUTDIR
< "$OUTDIR/cells.txt" xargs -n3 -P "$PAR" \
    bash -c '"$DRV" "$0" "$1" "$2" "$OUTDIR"'

echo "matrix-dispatch-batch2: done; logs in $OUTDIR" >&2
