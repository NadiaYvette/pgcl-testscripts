#!/bin/bash
set -u
SRC=/home/nyc/src/linux; O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
echo "=== rebuild kernel (free signal moved to __free_pages_prepare) $(date +%T) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -3
rc=${PIPESTATUS[0]}
if [ "$rc" != 0 ]; then echo "KERNEL-FAIL rc=$rc"; exit 1; fi
cp "$O/arch/x86/boot/bzImage" /home/nyc/src/pgcl/rmap-ab/bzImage-vandangle && echo "kernel OK $(date +%T)"
cd /home/nyc/src/pgcl/rmap-ab
N=1 bash run-dangle.sh
echo "=== channels ==="
echo "-- rec:"; grep -hcE 'PGCL143rec' dangle-1.log 2>/dev/null
echo "-- free signals:"; grep -hcE 'PGCL143free' dangle-1.log 2>/dev/null
echo "-- PGCL143free samples:"; grep -hE 'PGCL143free' dangle-1.log 2>/dev/null | head -4
echo "-- PGCL143dbg (validate attempts):"; grep -hE 'PGCL143dbg' dangle-1.log 2>/dev/null | head -12
echo "-- PGCL143dangle (CATCHES):"; grep -hE 'PGCL143dangle' dangle-1.log 2>/dev/null | head -12
