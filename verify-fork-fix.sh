#!/bin/bash
set -u
for i in 1 2 3; do
  L=/home/nyc/src/pgcl/ca-out/aarch64_forkfix_$i.log
  bash /home/nyc/src/pgcl/fast-aarch64.sh "$L" 1500 >/dev/null 2>&1
  m=$(grep -ciE 'Bad page state|bad_page|nonzero (map|ref)count|VM_BUG|still mapped|bad page map' "$L" 2>/dev/null)
  pd=$(grep -c 'remove-on-unmapped\|mapcount>refcount' "$L" 2>/dev/null)
  cow=$(grep -oE 'cow: (PASS|FAIL[^ ]*)' "$L" 2>/dev/null | tail -1)
  ltp=$(grep -oE 'LTP subtotals:.*' "$L" 2>/dev/null | tail -1)
  echo "RUN $i: markers=$m PGCLDBG=$pd | $cow | ${ltp:-<no LTP>}"
done
