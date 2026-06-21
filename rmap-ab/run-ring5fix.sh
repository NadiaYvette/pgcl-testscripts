#!/bin/bash
# A/B: delay_rmap-off fix kernel, -smp 8 on 16-19, 8 runs. Baseline (ring5b) = 6/8 died.
cd /home/nyc/src/pgcl/rmap-ab
for r in 1 2 3 4 5 6 7 8; do
  bash run-rr.sh bzImage-ring5-fix rr-ring5fix-$r.log 220 8 >/dev/null 2>&1
  L=rr-ring5fix-$r.log
  echo "run$r: anomaly=$(grep -ac 'PGCL#143: ===== anomaly' $L) badpage=$(grep -ac 'Bad page state' $L) filemap=$(grep -ac 'mapped@truncate' $L) panic=$(grep -ac 'Kernel panic' $L) killinit=$(grep -ac 'kill init' $L) login=$(grep -ac 'login:' $L)"
done
echo "=== ring5fix A/B done $(date +%H:%M:%S) ==="
