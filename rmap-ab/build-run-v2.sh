#!/bin/bash
set -u
echo "=== rebuild qemu v2 (reverse-map + free-time validate) $(date +%T) ==="
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-v2-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "QEMU-V2-BUILD-FAIL rc=$rc"; tail -30 /home/nyc/src/pgcl/qemu-v2-build.log; exit 1; fi
echo "qemu v2 OK $(date +%T)"
cd /home/nyc/src/pgcl/rmap-ab
N=2 bash run-dangle.sh
