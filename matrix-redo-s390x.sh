#!/bin/bash
set -u
export PATH="/usr/bin:$PATH"
DRV=/home/nyc/src/pgcl/matrix-driver-slow.sh
OUTDIR=/home/nyc/src/pgcl/matrix-20260429-200347
export DRV OUTDIR
< "$OUTDIR/cells-s390x-redo.txt" xargs -n3 -P 2 bash -c '"$DRV" "$0" "$1" "$2" "$OUTDIR"'
