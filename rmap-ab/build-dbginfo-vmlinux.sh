#!/bin/bash
set -u
SRC=/home/nyc/src/linux
O4=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
OD=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-dbginfo
mkdir -p "$OD"
cp "$O4/.config" "$OD/.config"
"$SRC/scripts/config" --file "$OD/.config" -e DEBUG_INFO -e DEBUG_INFO_DWARF5 -d DEBUG_INFO_NONE -e DEBUG_INFO_BTF
make -C "$SRC" O="$OD" olddefconfig > /home/nyc/src/pgcl/dbginfo-cfg.log 2>&1
echo "config: $(grep -E 'CONFIG_DEBUG_INFO=|DWARF5|_BTF=' "$OD/.config" | tr '\n' ' ')"
echo "=== build vmlinux w/ debug info $(date +%T) ==="
taskset -c 12-19 make -C "$SRC" O="$OD" -j8 vmlinux > /home/nyc/src/pgcl/dbginfo-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -20 /home/nyc/src/pgcl/dbginfo-build.log; exit 1; fi
echo "vmlinux built $(date +%T)"
echo "=== struct page layout ==="
pahole -C page "$OD/vmlinux" 2>/dev/null | sed -n '1,80p'
echo "=== sizeof + offsets of _refcount/_mapcount + vmemmap symbol ==="
pahole -C page "$OD/vmlinux" 2>/dev/null | grep -E '_refcount|_mapcount|_large_mapcount|size:|/\* size'
echo "vmemmap addr (nokaslr): $(nm "$OD/vmlinux" 2>/dev/null | grep -iE ' vmemmap$| page_offset_base| vmemmap_base' | head)"
