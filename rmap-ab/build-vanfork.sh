#!/bin/bash
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
BZ=/home/nyc/src/pgcl/rmap-ab/bzImage-vanfork
echo "=== build fork-tag kernel (memory.c forktag) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -6
rc=${PIPESTATUS[0]}
echo "make rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo BUILD-FAIL; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ" && echo "OK -> $BZ ($(du -h "$BZ"|cut -f1))"
