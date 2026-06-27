#!/bin/bash
# build-tripwire.sh — build the #143 light freeze-while-mapped tripwire kernel to
# bzImage-tripwire (keeps bzImage-vandangle intact as the known-good oracle).
set -u
SRC=/home/nyc/src/linux; O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
echo "=== build tripwire kernel -> bzImage-tripwire $(date +%T) ==="
echo "branch: $(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -8
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "KERNEL-FAIL rc=$rc"; exit 1; }
cp "$O/arch/x86/boot/bzImage" /home/nyc/src/pgcl/rmap-ab/bzImage-tripwire \
  && echo "OK -> bzImage-tripwire $(date +%T) ($(du -h /home/nyc/src/pgcl/rmap-ab/bzImage-tripwire | cut -f1))"
