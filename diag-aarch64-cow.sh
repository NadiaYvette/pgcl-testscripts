#!/bin/bash
set -u
O=/home/nyc/src/pgcl/diag-aarch64-cow-out; mkdir -p "$O"
echo "######## DIAG aarch64 PGCL=4 instrumented (PGCLDIAG) $(date +%H:%M:%S) ########"
BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on" MATRIX_J=20 \
  bash /home/nyc/src/pgcl/matrix-driver-all.sh /home/nyc/src/linux aarch64 4 "$O"
echo "######## DIAG DONE $(date +%H:%M:%S) ########"
