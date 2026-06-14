#!/bin/bash
set -u
O=/home/nyc/src/pgcl/diag-mc-shape-out; mkdir -p "$O"
echo "######## MC-SHAPE aarch64 PGCL=4 (residual distribution) $(date +%H:%M:%S) ########"
BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on" MATRIX_J=20 \
  bash /home/nyc/src/pgcl/matrix-driver-all.sh /home/nyc/src/linux aarch64 4 "$O"
echo "######## MC-SHAPE DONE $(date +%H:%M:%S) ########"
echo "--- PGCLMC residual lines ---"
grep -A0 'PGCLMC residual' "$O/aarch64_4.log" 2>/dev/null | head -8
