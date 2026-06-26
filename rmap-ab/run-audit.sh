#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
cd "$P/kernel-rpm-build/pgcl4"
echo "=== build bzImage (reclaim dangler audit) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanaudit-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { tail -25 "$P/vanaudit-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanaudit"
BZ="$D/bzImage-vanaudit" MEM=2G bash "$D/run-abl-qemu.sh" minimal 6
echo; echo "######## PGCL143dangle SURVIVORS (the prize) ########"
grep -haE 'PGCL143dangle:' $D/abl-minimal-2G-*.log 2>/dev/null | sed -E 's/^.*kernel: //' | sort | uniq -c | sort -rn | head -40
