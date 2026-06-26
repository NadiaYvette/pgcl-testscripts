#!/bin/bash
set -u
SRC=/home/nyc/src/linux; O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
echo "=== build kernel (fork-tag + qsig) -> bzImage-vandangle $(date +%T) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -4
krc=${PIPESTATUS[0]}
if [ "$krc" != 0 ]; then echo "KERNEL-FAIL rc=$krc"; exit 1; fi
cp "$O/arch/x86/boot/bzImage" /home/nyc/src/pgcl/rmap-ab/bzImage-vandangle && echo "kernel OK -> bzImage-vandangle"
echo "=== build qemu (dangling-PTE probe) $(date +%T) ==="
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-dangle-build.log 2>&1
qrc=$?
if [ "$qrc" != 0 ]; then echo "QEMU-FAIL rc=$qrc"; tail -30 /home/nyc/src/pgcl/qemu-dangle-build.log; exit 1; fi
echo "=== BOTH BUILT OK $(date +%T) ==="
