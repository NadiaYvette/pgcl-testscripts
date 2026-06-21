#!/bin/bash
# Sequential RR runs against the #143 underflow-diagnostic kernel.
cd /home/nyc/src/pgcl/rmap-ab
for r in 1 2 3 4 5 6; do
  bash run-rr.sh bzImage-143diag rr-143diag-$r.log 220 8 >/dev/null 2>&1
  L=rr-143diag-$r.log
  echo "run$r: PGCL143=$(grep -ac 'PGCL#143' $L) underflow=$(grep -ac 'order-0 mapcount underflow' $L) nmibt=$(grep -ac 'NMI backtrace' $L) panic=$(grep -ac 'Kernel panic' $L) killinit=$(grep -ac 'kill init' $L) login=$(grep -ac 'login:' $L)"
done
echo "=== 143diag batch done $(date +%H:%M:%S) ==="
