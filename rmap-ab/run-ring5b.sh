#!/bin/bash
# ring5 re-run with the proven catch config: -smp 8 on 16-19 (2x oversub), 8 runs.
cd /home/nyc/src/pgcl/rmap-ab
for r in 1 2 3 4 5 6 7 8; do
  bash run-rr.sh bzImage-ring5 rr-ring5b-$r.log 220 8 >/dev/null 2>&1
  L=rr-ring5b-$r.log
  echo "run$r: anomaly=$(grep -ac 'PGCL#143: ===== anomaly' $L) SUM=$(grep -ac 'PGCL#143:   SUM' $L) freed=$(grep -aE 'PGCL#143: folio=' $L | grep -ac 'refcount=0 ') large=$(grep -ac 'LARGE _large' $L) filemap=$(grep -ac 'mapped@truncate' $L) badpage=$(grep -ac 'Bad page state' $L) panic=$(grep -ac 'Kernel panic' $L) login=$(grep -ac 'login:' $L)"
done
echo "=== ring5b batch done $(date +%H:%M:%S) ==="
