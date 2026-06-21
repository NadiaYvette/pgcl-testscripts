#!/bin/bash
# Sequential RR runs against the per-pfn-ring + bad_page-hook + enriched-mapper kernel.
cd /home/nyc/src/pgcl/rmap-ab
for r in 1 2 3 4 5 6; do
  bash run-rr.sh bzImage-ring3 rr-ring3-$r.log 220 8 >/dev/null 2>&1
  L=rr-ring3-$r.log
  echo "run$r: anomaly=$(grep -ac 'PGCL#143: ===== anomaly' $L) ring=$(grep -ac 'count-history pfn' $L) SUM=$(grep -ac 'PGCL#143:   SUM' $L) large=$(grep -ac 'LARGE _large_mapcount' $L) filemap=$(grep -ac 'mapped@truncate' $L) badpage=$(grep -ac 'Bad page state' $L) panic=$(grep -ac 'Kernel panic' $L) killinit=$(grep -ac 'kill init' $L) login=$(grep -ac 'login:' $L)"
done
echo "=== ring3 batch done $(date +%H:%M:%S) ==="
