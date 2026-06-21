#!/bin/bash
# Sequential RR runs against ring4 (mismatch probe + order-0 add gaps closed).
cd /home/nyc/src/pgcl/rmap-ab
for r in 1 2 3 4 5 6; do
  bash run-rr.sh bzImage-ring4 rr-ring4-$r.log 220 8 >/dev/null 2>&1
  L=rr-ring4-$r.log
  echo "run$r: anomaly=$(grep -ac 'PGCL#143: ===== anomaly' $L) SUM=$(grep -ac 'PGCL#143:   SUM' $L) mismatch=$(grep -ac 'sub-PTE pfn outside folio' $L) large=$(grep -ac 'LARGE _large_mapcount' $L) filemap=$(grep -ac 'mapped@truncate' $L) badpage=$(grep -ac 'Bad page state' $L) panic=$(grep -ac 'Kernel panic' $L) killinit=$(grep -ac 'kill init' $L) login=$(grep -ac 'login:' $L)"
done
echo "=== ring4 batch done $(date +%H:%M:%S) ==="
