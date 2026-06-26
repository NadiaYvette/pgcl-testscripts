#!/bin/bash
set -u
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-v2dbg-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/qemu-v2dbg-build.log; exit 1; fi
echo "qemu v2dbg OK $(date +%T)"
cd /home/nyc/src/pgcl/rmap-ab
N=1 bash run-dangle.sh
echo "=== PGCL143dbg validate attempts (does the walk read + match?) ==="
grep -hE 'PGCL143dbg|PGCL143dangle' /home/nyc/src/pgcl/rmap-ab/dangle-1.log 2>/dev/null | head -30
