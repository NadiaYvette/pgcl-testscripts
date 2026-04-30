#!/bin/bash
# Resume matrix run from cells-resume.txt with fixed (no-pkill) driver.
set -u
export PATH="/usr/bin:$PATH"
D=/home/nyc/src/pgcl
DRV="$D/matrix-driver.sh"
OUTDIR="$D/matrix-20260429-200347"
PAR=${PAR:-2}

echo "matrix-resume: OUTDIR=$OUTDIR PAR=$PAR cells:" >&2
cat "$OUTDIR/cells-resume.txt" >&2

export DRV OUTDIR
< "$OUTDIR/cells-resume.txt" xargs -n3 -P "$PAR" \
    bash -c '"$DRV" "$0" "$1" "$2" "$OUTDIR"'

echo "matrix-resume: done" >&2
