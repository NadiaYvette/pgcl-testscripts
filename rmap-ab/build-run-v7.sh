#!/bin/bash
set -u
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-v7-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/qemu-v7-build.log; exit 1; fi
echo "qemu v7 OK $(date +%T)"
cd /home/nyc/src/pgcl/rmap-ab
N=1 bash run-dangle.sh
echo "=== SELFTEST (want WALK-OK) + per-level walk ==="
grep -hE 'walk lvl|PGCL143rec' dangle-1.log 2>/dev/null | head -16
echo "=== validate verdicts (PGCL143dbg) ==="
grep -hE 'PGCL143dbg' dangle-1.log 2>/dev/null | grep -E 'MATCH|other-frame|gone' | sort | uniq -c | head
echo "=== DANGLE CATCHES ==="
grep -hE 'PGCL143dangle' dangle-1.log 2>/dev/null | head -10
