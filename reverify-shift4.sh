#!/bin/bash
set -u
O=/home/nyc/src/pgcl/pgcl-diag-reverify; mkdir -p "$O"
echo "######## REVERIFY shift=4 (post sys_x86_64 fix) $(date +%H:%M:%S) ########"
BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on" MATRIX_J=20 BIGRAM_MEM=8G BIGRAM_SMP=4 \
  bash /home/nyc/src/pgcl/matrix-driver-bigram.sh /home/nyc/src/linux x86_64 4 "$O"
L="$O/x86_64_4.log"
real=$(grep -ciE 'Bad page state|BUG:|kernel BUG at|invalid opcode|VM_BUG|bad_page|still mapped|nonzero (map|ref)count|Attempted to kill init' "$L" 2>/dev/null)
echo ">>> shift=4 REVERIFY: real-corruption-markers=$real | $(grep -oE 'LTP subtotals:.*' "$L" 2>/dev/null | tail -1)"
echo "######## REVERIFY DONE $(date +%H:%M:%S) ########"
