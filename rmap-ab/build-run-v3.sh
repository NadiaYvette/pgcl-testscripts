#!/bin/bash
set -u
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-v3-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/qemu-v3-build.log; exit 1; fi
echo "qemu v3 OK $(date +%T)"
cd /home/nyc/src/pgcl/rmap-ab
N=1 bash run-dangle.sh
echo "=== PGCL143rec (recorded frames) ==="
grep -hE 'PGCL143rec' /home/nyc/src/pgcl/rmap-ab/dangle-1.log 2>/dev/null | head -8
echo "=== PGCL143free (freed-frame bases) ==="
grep -hE 'PGCL143free' /home/nyc/src/pgcl/rmap-ab/dangle-1.log 2>/dev/null | head -8
echo "=== PGCL143dbg / dangle catches ==="
grep -hE 'PGCL143dbg|PGCL143dangle' /home/nyc/src/pgcl/rmap-ab/dangle-1.log 2>/dev/null | head -8
