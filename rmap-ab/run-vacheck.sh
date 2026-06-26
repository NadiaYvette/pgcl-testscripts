#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
cd "$P/kernel-rpm-build/pgcl4"
echo "=== build bzImage (install-VA check) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanva-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { tail -25 "$P/vanva-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanva"
BZ="$D/bzImage-vanva" MEM=2G bash "$D/run-abl-qemu.sh" minimal 6
echo; echo "######## PGCL143vamiss (install VA != rmap VA) ########"
grep -haE 'PGCL143vamiss:' $D/abl-minimal-2G-*.log 2>/dev/null | sed -E 's/^.*kernel: //' | sort | uniq -c | sort -rn | head -30
echo "  total vamiss lines: $(grep -hac 'PGCL143vamiss:' $D/abl-minimal-2G-*.log 2>/dev/null | paste -sd+ | bc 2>/dev/null)"
