#!/bin/bash
# run-ca-cell.sh ARCH CONFIG  — verify Contract-A worktree, un-silenced
set -u
A=$1; C=$2
WT=/home/nyc/src/linux-pgcl-mc
OUT=/home/nyc/src/pgcl/ca-out
L="$OUT/${A}_${C}.log"
echo "######## CA CELL ${A}_${C} START $(date +%H:%M:%S) ########"
BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on" MATRIX_J=10 \
  bash /home/nyc/src/pgcl/matrix-driver-ca.sh "$WT" "$A" "$C" "$OUT" >/dev/null 2>&1
real=$(grep -ciE 'Bad page state|kernel BUG at|invalid opcode|VM_BUG|bad_page|free_page_is_bad|print_bad_pte|still mapped|nonzero (map|ref)count|Attempted to kill init' "$L" 2>/dev/null || echo 0)
ltp=$(grep -oE 'LTP subtotals:.*' "$L" 2>/dev/null | tail -1)
init=$(grep -qE 'Run /init as init process' "$L" 2>/dev/null && echo init-ok || echo NO-INIT)
echo ">>> CA CELL ${A}_${C}: markers=$real $init | ${ltp:-<no LTP line>}  ($(date +%H:%M:%S))"
