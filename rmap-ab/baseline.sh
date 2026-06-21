#!/bin/bash
set -u
for r in 1 2 3 4 5; do
  bash /home/nyc/src/pgcl/rmap-ab/run-rr.sh /home/nyc/src/pgcl/rmap-ab/bzImage-probe2 /home/nyc/src/pgcl/rmap-ab/base-$r.log 150 8 >/dev/null 2>&1
  L=/home/nyc/src/pgcl/rmap-ab/base-$r.log
  echo "run$r: segv=$(grep -ac 'systemd\[1\]: segfault' $L) panic=$(grep -ac 'Kernel panic' $L) PGCLUF=$(grep -ac PGCLUF-RM $L) login=$(grep -ac 'login:' $L)"
done
echo "=== BASELINE done ==="
