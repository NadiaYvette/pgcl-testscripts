#!/bin/bash
# matrix-dispatch.sh: drive matrix-driver.sh over a (LINUX_DIR, ARCH, CONFIG) cell list
# with bounded parallelism.  Each cell goes to its own log under OUTDIR.

set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
DRV="$D/matrix-driver.sh"
LX_PGCL=/home/nyc/src/linux
LX_MAIN=/home/nyc/src/linux-mainline
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$D/matrix-$TS"
PAR=${PAR:-2}

mkdir -p "$OUTDIR"
echo "matrix-dispatch: OUTDIR=$OUTDIR PAR=$PAR" >&2

# 7 fast arches first; expand later.
ARCHES_FAST="x86_64 aarch64 riscv64 ppc64 s390x sparc64 loongarch64"
CONFIGS="mainline 4"

# Build cell list: one space-separated triple per line.
{
  for ARCH in $ARCHES_FAST; do
    for CFG in $CONFIGS; do
      if [ "$CFG" = "mainline" ]; then
        LX="$LX_MAIN"
      else
        LX="$LX_PGCL"
      fi
      printf '%s %s %s\n' "$LX" "$ARCH" "$CFG"
    done
  done
} > "$OUTDIR/cells.txt"

echo "cells:" >&2
cat "$OUTDIR/cells.txt" >&2

# Use xargs -n3 to feed three args (LINUX ARCH CONFIG) per invocation
# of a tiny shim that appends OUTDIR as the 4th arg.
export DRV OUTDIR
< "$OUTDIR/cells.txt" xargs -n3 -P "$PAR" \
    bash -c '"$DRV" "$0" "$1" "$2" "$OUTDIR"'

echo "matrix-dispatch: done; logs in $OUTDIR" >&2
ls -la "$OUTDIR" >&2
