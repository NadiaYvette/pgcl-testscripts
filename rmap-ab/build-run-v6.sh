#!/bin/bash
set -u
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-v6-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -20 /home/nyc/src/pgcl/qemu-v6-build.log; exit 1; fi
echo "qemu v6 OK $(date +%T)"
cd /home/nyc/src/pgcl/rmap-ab
N=1 bash run-dangle.sh
echo "=== per-level walk trace + selftest verdict ==="
grep -hE 'walk lvl|PGCL143rec' dangle-1.log 2>/dev/null | head -30
