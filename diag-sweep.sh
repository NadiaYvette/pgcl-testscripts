#!/bin/bash
set -u
O=/home/nyc/src/pgcl/pgcl-diag-sweep; mkdir -p "$O"
for N in 4 0; do
  echo "######## DEBUG shift=$N $(date +%H:%M:%S) ########"
  BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on" MATRIX_J=20 BIGRAM_MEM=8G BIGRAM_SMP=4 \
    bash /home/nyc/src/pgcl/matrix-driver-bigram.sh /home/nyc/src/linux x86_64 "$N" "$O"
  L="$O/x86_64_${N}.log"
  hits=$(grep -ciE 'Bad page state|BUG:|VM_BUG|bad_page|page_owner|still mapped|nonzero (map|ref)count' "$L" 2>/dev/null)
  echo ">>> shift=$N: corruption-markers=$hits | $(grep -oE 'LTP subtotals:.*' "$L" 2>/dev/null | tail -1)"
done
echo "######## DIAG DONE $(date +%H:%M:%S) ########"
