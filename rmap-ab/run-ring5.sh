#!/bin/bash
# Sequential RR runs against ring5 (generation-tracked ring + refcount-0 flag), -smp 16.
cd /home/nyc/src/pgcl/rmap-ab
for r in 1 2 3 4 5 6; do
  bash run-rr.sh bzImage-ring5 rr-ring5-$r.log 220 16 >/dev/null 2>&1
  L=rr-ring5-$r.log
  echo "run$r: anomaly=$(grep -ac 'PGCL#143: ===== anomaly' $L) SUM=$(grep -ac 'PGCL#143:   SUM' $L) freed=$(grep -aE 'PGCL#143: folio=' $L | grep -ac 'refcount=0 ') mismatch=$(grep -ac 'pfn outside folio' $L) large=$(grep -ac 'LARGE _large' $L) filemap=$(grep -ac 'mapped@truncate' $L) badpage=$(grep -ac 'Bad page state' $L) panic=$(grep -ac 'Kernel panic' $L) killinit=$(grep -ac 'kill init' $L) login=$(grep -ac 'login:' $L)"
done
echo "=== ring5 batch done $(date +%H:%M:%S) ==="
